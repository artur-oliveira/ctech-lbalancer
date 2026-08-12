import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import test from 'node:test';
import * as cdk from 'aws-cdk-lib';
import {Template} from 'aws-cdk-lib/assertions';
import {buildUserData} from '../lib/user-data';
import {defaultRoutes, HAPROXY_SHA256, HAPROXY_VERSION, originDomainForEnv} from '../lib/constants';
import {LoadBalancerStack} from '../lib/load-balancer-stack';

test('pins the current HAProxy LTS patch and checksum', () => {
  assert.equal(HAPROXY_VERSION, '3.4.3');
  assert.match(HAPROXY_SHA256, /^[a-f0-9]{64}$/);
});

test('uses API origins and the existing service ASG contracts', () => {
  const routes = defaultRoutes('prod');
  assert.equal(routes.account?.hostname, 'accounts-api.aoctech.app');
  assert.equal(routes.dfe?.asg, 'prod-ctech-dfe-v2-api');
  assert.equal(routes.wallet?.asg, 'prod-ctech-wallet-v2-api');
  assert.equal(routes.poker?.port, 8080);
  assert.equal(originDomainForEnv('stage'), 'origin-stage.aoctech.app');
});

test('compressed user data stays below the EC2 16 KiB raw limit', () => {
  const rendered = buildUserData({
    environment: 'prod',
    region: 'us-east-1',
    cloudflareZoneId: 'zone-id',
    enableCloudWatchMetrics: false,
    accessLogGroupName: '/ctech-lbalancer/prod/access',
  }).render();
  assert.ok(Buffer.byteLength(rendered) < 16 * 1024, `user data is ${Buffer.byteLength(rendered)} bytes`);
  assert.doesNotMatch(rendered, /__HAPROXY_VERSION__|__AWS_REGION__|__ROUTES_PATH__/);
});

test('bootstrap keeps curl-minimal and starts SSM before building HAProxy', () => {
  const bootstrap = readFileSync(join(__dirname, '..', 'assets', 'bootstrap.sh'), 'utf8');
  const runtimePackages = bootstrap.match(/^RUNTIME_PACKAGES=\(([^)]*)\)$/m)?.[1];
  assert.ok(runtimePackages);
  assert.doesNotMatch(runtimePackages, /(^|\s)curl($|\s)/);
  assert.ok(
    bootstrap.indexOf('systemctl restart amazon-ssm-agent') < bootstrap.indexOf("HAPROXY_VERSION="),
    'SSM must start before the HAProxy download and build',
  );
  assert.match(bootstrap, /"Region": "__AWS_REGION__", "UseDualStackEndpoint": true/);
});

test('synthesizes one IPv6-only ASG and four standard route parameters', () => {
  const app = new cdk.App();
  const stack = new LoadBalancerStack(app, 'TestStack', {
    env: {account: '111111111111', region: 'us-east-1'},
    environment: 'prod',
    vpcId: 'vpc-12345',
    instanceType: 't4g.nano',
    enableCloudWatchMetrics: false,
  });
  const template = Template.fromStack(stack);
  template.resourceCountIs('AWS::AutoScaling::AutoScalingGroup', 1);
  // Account, DFE, wallet, and poker API routes.
  template.resourceCountIs('AWS::SSM::Parameter', 4);
  template.hasResourceProperties('AWS::EC2::LaunchTemplate', {
    LaunchTemplateData: {
      CreditSpecification: {CpuCredits: 'unlimited'},
      NetworkInterfaces: [{
        AssociatePublicIpAddress: false,
        DeviceIndex: 0,
        Ipv6AddressCount: 1,
      }],
    },
  });
  const launchTemplates = template.findResources('AWS::EC2::LaunchTemplate');
  const launchTemplate = Object.values(launchTemplates)[0];
  const networkInterfaces = launchTemplate?.Properties?.LaunchTemplateData?.NetworkInterfaces;
  assert.equal(networkInterfaces?.[0]?.Groups?.length, 2);
  const securityGroups = template.findResources('AWS::EC2::SecurityGroup');
  const ipv6EgressGroup = Object.values(securityGroups).find(resource =>
    resource.Properties?.GroupDescription === 'IPv6 internet egress for the CTech HAProxy instance');
  assert.ok(ipv6EgressGroup);
  assert.ok(ipv6EgressGroup.Properties?.SecurityGroupEgress?.some(
    (rule: {CidrIpv6?: string; IpProtocol?: string}) =>
      rule.CidrIpv6 === '::/0' && rule.IpProtocol === '-1',
  ));
});
