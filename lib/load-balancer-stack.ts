import * as cdk from 'aws-cdk-lib';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import {Construct} from 'constructs';
import {defaultRoutes, HAPROXY_VERSION, originDomainForEnv, ssmPaths} from './constants';
import {Environment} from './types';
import {buildUserData} from './user-data';

export interface LoadBalancerStackProps extends cdk.StackProps {
  environment: Environment;
  vpcId: string;
  instanceType: string;
  cloudflareZoneId?: string;
  enableCloudWatchMetrics: boolean;
  artifactBucket: s3.IBucket;
  artifactBucketName: string;
}

const STATUS_PATTERNS: ReadonlyArray<[string, string]> = [
  ['HTTP2XX', '{ ($.status >= 200) && ($.status < 300) }'],
  ['HTTP3XX', '{ ($.status >= 300) && ($.status < 400) }'],
  ['HTTP4XX', '{ ($.status >= 400) && ($.status < 500) }'],
  ['HTTP5XX', '{ $.status >= 500 }'],
];

export class LoadBalancerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LoadBalancerStackProps) {
    super(scope, id, props);

    const {environment} = props;
    const paths = ssmPaths(environment);
    const vpc = ec2.Vpc.fromLookup(this, 'Vpc', {vpcId: props.vpcId});
    const edgeSgId = ssm.StringParameter.valueForStringParameter(this, paths.edgeSecurityGroupId);
    const edgeSg = ec2.SecurityGroup.fromSecurityGroupId(this, 'EdgeSg', edgeSgId, {
      mutable: false,
    });
    // The imported ALB SG has IPv4-only default egress. Keep it attached because
    // the service instance SGs trust it, and add a scoped second SG so this
    // public-IPv6/no-public-IPv4 instance can reach SSM and package endpoints.
    const ipv6EgressSg = new ec2.SecurityGroup(this, 'Ipv6EgressSg', {
      vpc,
      securityGroupName: `${environment}-ctech-lbalancer-ipv6-egress-sg`,
      description: 'IPv6 internet egress for the CTech HAProxy instance',
      allowAllOutbound: false,
      allowAllIpv6Outbound: true,
    });

    const role = new iam.Role(this, 'InstanceRole', {
      roleName: `${environment}-ctech-lbalancer`,
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
      resources: [
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.routes}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.routes}/*`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.tlsCertificate}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.tlsPrivateKey}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.aopCa}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.cloudflareDnsToken}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.haproxyArtifactSha256}`,
      ],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:PutParameter'],
      resources: [
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.originIpv6}`,
        `arn:${cdk.Aws.PARTITION}:ssm:${this.region}:${this.account}:parameter${paths.haproxyArtifactSha256}`,
      ],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject', 's3:PutObject', 's3:AbortMultipartUpload'],
      resources: [props.artifactBucket.arnForObjects('*')],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['autoscaling:DescribeAutoScalingGroups', 'ec2:DescribeInstances'],
      resources: ['*'],
    }));
    // Auto-healing is route opt-in. SetInstanceHealth has no useful dynamic
    // resource scope because future routes can name ASGs without changing this stack.
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['autoscaling:SetInstanceHealth'],
      resources: ['*'],
    }));

    const accessLogGroup = new logs.LogGroup(this, 'AccessLogs', {
      logGroupName: `/ctech-lbalancer/${environment}/access`,
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: environment === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });
    if (props.enableCloudWatchMetrics) {
      role.addToPolicy(new iam.PolicyStatement({
        actions: ['logs:CreateLogStream', 'logs:DescribeLogStreams', 'logs:PutLogEvents'],
        resources: [`${accessLogGroup.logGroupArn}:*`],
      }));
      for (const [name, pattern] of STATUS_PATTERNS) {
        new logs.MetricFilter(this, `${name}Filter`, {
          logGroup: accessLogGroup,
          metricNamespace: `CtechLoadBalancer/${environment}`,
          metricName: name,
          filterPattern: logs.FilterPattern.literal(pattern),
          metricValue: '1',
          defaultValue: 0,
        });
      }
    }

    const profile = new iam.CfnInstanceProfile(this, 'InstanceProfile', {
      roles: [role.roleName],
      instanceProfileName: `${environment}-ctech-lbalancer`,
    });

    const launchTemplate = new ec2.LaunchTemplate(this, 'LaunchTemplate', {
      launchTemplateName: `${environment}-ctech-lbalancer`,
      instanceType: new ec2.InstanceType(props.instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.ARM_64,
        edition: ec2.AmazonLinuxEdition.MINIMAL,
      }),
      // T4g has no launch credits. Unlimited lets a replacement compile HAProxy
      // promptly; the one-time burst is repaid by the otherwise-idle 24h baseline.
      cpuCredits: ec2.CpuCredits.UNLIMITED,
      blockDevices: [{
        deviceName: '/dev/xvda',
        // Four GiB leaves enough temporary headroom for the verified source build
        // plus swap; shrinking to three saves only about $0.08/month and risks boot.
        volume: ec2.BlockDeviceVolume.ebs(4, {
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          deleteOnTermination: true,
          encrypted: true,
        }),
      }],
      userData: buildUserData({
        environment,
        region: this.region,
        cloudflareZoneId: props.cloudflareZoneId,
        enableCloudWatchMetrics: props.enableCloudWatchMetrics,
        accessLogGroupName: accessLogGroup.logGroupName,
        artifactBucketName: props.artifactBucketName,
      }),
      instanceProfile: iam.InstanceProfile.fromInstanceProfileName(
        this,
        'ImportedInstanceProfile',
        profile.ref,
      ),
      requireImdsv2: true,
      securityGroup: edgeSg,
    });
    launchTemplate.node.addDependency(profile);

    const cfnLaunchTemplate = launchTemplate.node.defaultChild as ec2.CfnLaunchTemplate;
    cfnLaunchTemplate.addPropertyDeletionOverride('LaunchTemplateData.SecurityGroupIds');
    cfnLaunchTemplate.addPropertyOverride('LaunchTemplateData.NetworkInterfaces', [{
      DeviceIndex: 0,
      Groups: [edgeSg.securityGroupId, ipv6EgressSg.securityGroupId],
      AssociatePublicIpAddress: false,
      Ipv6AddressCount: 1,
    }]);

    const asg = new autoscaling.AutoScalingGroup(this, 'Asg', {
      autoScalingGroupName: `${environment}-ctech-lbalancer`,
      vpc,
      vpcSubnets: {subnetType: ec2.SubnetType.PUBLIC},
      launchTemplate,
      minCapacity: 1,
      maxCapacity: 1,
      healthChecks: autoscaling.HealthChecks.ec2({gracePeriod: cdk.Duration.minutes(10)}),
    });
    asg.node.addDependency(profile);

    for (const [name, route] of Object.entries(defaultRoutes(environment))) {
      new ssm.StringParameter(this, `${name}Route`, {
        parameterName: `${paths.routes}/${name}`,
        tier: ssm.ParameterTier.STANDARD,
        stringValue: JSON.stringify(route),
        description: `HAProxy route for ${route.hostname}`,
      });
    }

    new cdk.CfnOutput(this, 'AutoScalingGroupName', {value: asg.autoScalingGroupName});
    new cdk.CfnOutput(this, 'OriginHostname', {value: originDomainForEnv(environment)});
    new cdk.CfnOutput(this, 'OriginIpv6Parameter', {value: paths.originIpv6});
    new cdk.CfnOutput(this, 'RouteParameterPrefix', {value: paths.routes});
    new cdk.CfnOutput(this, 'HAProxyVersion', {value: HAPROXY_VERSION});
    new cdk.CfnOutput(this, 'HAProxyArtifactBucket', {value: props.artifactBucket.bucketName});
    new cdk.CfnOutput(this, 'HAProxyArtifactHashParameter', {value: paths.haproxyArtifactSha256});
    new cdk.CfnOutput(this, 'CloudWatchMetricsEnabled', {
      value: props.enableCloudWatchMetrics ? 'true' : 'false',
    });
  }
}
