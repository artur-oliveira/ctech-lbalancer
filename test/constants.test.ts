import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import test from 'node:test';
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import {Template} from 'aws-cdk-lib/assertions';
import {ArtifactStack} from '../lib/artifact-stack';
import {buildUserData} from '../lib/user-data';
import {
  defaultRoutes,
  DEFAULT_CLOUDFLARE_ZONE_ID,
  HAPROXY_ARTIFACT_BUCKET_NAME,
  HAPROXY_SOURCE_SHA256,
  HAPROXY_VERSION,
  originDomainForEnv,
} from '../lib/constants';
import {LoadBalancerStack} from '../lib/load-balancer-stack';

test('pins the current HAProxy LTS patch and checksum', () => {
  assert.equal(HAPROXY_VERSION, '3.4.3');
  assert.match(HAPROXY_SOURCE_SHA256, /^[a-f0-9]{64}$/);
  assert.match(DEFAULT_CLOUDFLARE_ZONE_ID, /^[a-f0-9]{32}$/);
});

test('uses API origins and the existing service ASG contracts', () => {
  const routes = defaultRoutes('prod');
  assert.equal(routes.account?.hostname, 'accounts-api.aoctech.app');
  assert.equal(routes.account?.asg, 'prod-ctech-account');
  assert.equal(routes.dfe?.asg, 'prod-ctech-dfe');
  assert.equal(routes.wallet?.asg, 'prod-ctech-wallet');
  assert.equal(routes.poker?.asg, 'prod-ctech-poker');
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
    artifactBucketName: '111111111111-us-east-1-ctech-lbalancer-artifacts',
  }).render();
  assert.ok(Buffer.byteLength(rendered) < 16 * 1024, `user data is ${Buffer.byteLength(rendered)} bytes`);
  assert.doesNotMatch(rendered, /__HAPROXY_VERSION__|__AWS_REGION__|__ROUTES_PATH__/);
});

test('rejects unresolved CDK tokens in compressed user data', () => {
  assert.throws(() => buildUserData({
    environment: 'prod',
    region: 'us-east-1',
    enableCloudWatchMetrics: false,
    accessLogGroupName: '/ctech-lbalancer/prod/access',
    artifactBucketName: cdk.Token.asString({Ref: 'ArtifactBucket'}),
  }), /artifactBucketName must be a physical name/);
  assert.throws(() => buildUserData({
    environment: 'prod',
    region: 'us-east-1',
    enableCloudWatchMetrics: true,
    accessLogGroupName: cdk.Token.asString({Ref: 'AccessLogGroup'}),
    artifactBucketName: HAPROXY_ARTIFACT_BUCKET_NAME,
  }), /accessLogGroupName must be a physical name/);
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
  assert.doesNotMatch(bootstrap, /haproxy -vv \| head/);
  assert.match(bootstrap, /--key "\$artifact_sha256"/);
  assert.match(bootstrap, /sha256sum --check --strict/);
});

test('reconciler keeps the jq status separator inside its filter', () => {
  const reconcile = readFileSync(join(__dirname, '..', 'assets', 'reconcile.sh'), 'utf8');
  assert.match(
    reconcile,
    /jq -r --argjson index "\$index" \\\n\s+'\.\[\$index\]\.healthyStatuses \| map\(tostring\) \| join\("\|"\)'/,
  );
  assert.doesNotMatch(reconcile, /map\(tostring\) \| join\("\|"\)"/);
  assert.match(reconcile, /default_backend unknown_host/);
  assert.match(reconcile, /backend unknown_host\n  http-request return status 421/);
  assert.match(
    reconcile,
    /http-error status 503 content-type application\/json string '\{"message": "Unavailable service"\}'/,
  );
  assert.match(reconcile, /\[ "\$old_proxied" != 'false' \]/);
  assert.doesNotMatch(reconcile, /use_backend[^\n]*\n(?:.|\n)*?http-request return status 421[^\n]*\n\nfrontend local_stats/);
});

test('reconciler resolves the client IP by stripping only trusted stacked-CDN hops', () => {
  const reconcile = readFileSync(join(__dirname, '..', 'assets', 'reconcile.sh'), 'utf8');
  const start = reconcile.indexOf('frontend https');
  const end = reconcile.indexOf('frontend local_stats');
  const frontend = reconcile.slice(start, end);

  assert.match(frontend, /cf_connecting_is_cloudfront req\.hdr_ip\(CF-Connecting-IP\) -m ip -f \/etc\/haproxy\/cloudfront-origin-proxies\.lst/);
  assert.match(frontend, /xff_last_is_cloudfront req\.hdr_ip\(X-Forwarded-For,-1\) -m ip -f \/etc\/haproxy\/cloudfront-origin-proxies\.lst/);
  assert.match(frontend, /xff_penultimate_is_cloudflare req\.hdr_ip\(X-Forwarded-For,-2\) -m ip -f \/etc\/haproxy\/cloudflare-proxies\.lst/);
  assert.match(frontend, /set-var\(txn\.client_ip\) req\.hdr_ip\(X-Forwarded-For,-2\) if cf_connecting_is_cloudfront xff_last_is_cloudfront/);
  assert.match(frontend, /set-var\(txn\.client_ip\) req\.hdr_ip\(X-Forwarded-For,-3\) if cf_connecting_is_cloudfront xff_last_is_cloudfront xff_penultimate_is_cloudflare/);
  assert.match(frontend, /set-header X-Forwarded-For %\[var\(txn\.client_ip\)\]/);
  assert.match(frontend, /set-header X-Real-IP %\[var\(txn\.client_ip\)\]/);
  assert.ok(frontend.indexOf('req.hdr_ip(X-Forwarded-For,-3)') < frontend.indexOf('del-header X-Forwarded-For'));
  assert.doesNotMatch(frontend, /set-header X-Forwarded-For %\[req\.hdr\(CF-Connecting-IP\)\]/);
});

test('trusted CDN ranges use IPv6-capable refresh paths and retain safe fallbacks', () => {
  const refresh = readFileSync(join(__dirname, '..', 'assets', 'refresh-cloudflare-ips.sh'), 'utf8');
  const stack = readFileSync(join(__dirname, '..', 'lib', 'load-balancer-stack.ts'), 'utf8');
  assert.match(refresh, /https:\/\/www\.cloudflare\.com\/ips-v4/);
  assert.match(refresh, /https:\/\/www\.cloudflare\.com\/ips-v6/);
  assert.match(refresh, /com\.amazonaws\.global\.cloudfront\.origin-facing/);
  assert.match(refresh, /describe-managed-prefix-lists/);
  assert.match(refresh, /get-managed-prefix-list-entries/);
  assert.match(refresh, /AWS_USE_DUALSTACK_ENDPOINT=true/);
  assert.doesNotMatch(refresh, /ip-ranges\.amazonaws\.com\/ip-ranges\.json/);
  assert.match(refresh, /15\.158\.0\.0\/16/);
  assert.match(refresh, /elif \[ -s "\$CLOUDFRONT_PROXY_LIST" \]/);
  assert.match(refresh, /haproxy -c -f \/etc\/haproxy\/haproxy\.cfg/);
  assert.match(stack, /'ec2:DescribeManagedPrefixLists'/);
  assert.match(stack, /'ec2:GetManagedPrefixListEntries'/);
});

test('HAProxy access logs isolate backend timing and identify the Cloudflare origin connection', () => {
  const reconcile = readFileSync(join(__dirname, '..', 'assets', 'reconcile.sh'), 'utf8');
  for (const field of [
    'cf_ray',
    'tls_protocol',
    'tls_cipher',
    'request_receive_time_ms',
    'queue_time_ms',
    'backend_connect_time_ms',
    'backend_response_time_ms',
    'total_time_ms',
    'termination_state',
  ]) {
    assert.match(reconcile, new RegExp(`\\\\"${field}\\\\"`));
  }
  assert.match(reconcile, /capture request header CF-Ray len 128/);
  assert.match(reconcile, /capture\.req\.hdr\(1\),json\(utf8s\)/);
  assert.doesNotMatch(reconcile, /req\.uri|req\.hdr\(Cookie\)|req\.hdr\(Authorization\)/);
});

test('retains the global artifact bucket without an expiration rule', () => {
  const app = new cdk.App();
  const stack = new ArtifactStack(app, 'ArtifactStack', {
    env: {account: '111111111111', region: 'us-east-1'},
  });
  const template = Template.fromStack(stack);
  const buckets = template.findResources('AWS::S3::Bucket');
  const bucket = Object.values(buckets)[0];
  assert.ok(bucket);
  assert.equal(bucket.DeletionPolicy, 'Retain');
  assert.equal(bucket.UpdateReplacePolicy, 'Retain');
  assert.equal(bucket.Properties?.LifecycleConfiguration, undefined);
  assert.deepEqual(bucket.Properties?.PublicAccessBlockConfiguration, {
    BlockPublicAcls: true,
    BlockPublicPolicy: true,
    IgnorePublicAcls: true,
    RestrictPublicBuckets: true,
  });
});

test('synthesizes one IPv6-only ASG and four standard route parameters', () => {
  const app = new cdk.App();
  const artifactStack = new cdk.Stack(app, 'ArtifactTestStack', {
    env: {account: '111111111111', region: 'us-east-1'},
  });
  const artifactBucket = new s3.Bucket(artifactStack, 'ArtifactBucket');
  const stack = new LoadBalancerStack(app, 'TestStack', {
    env: {account: '111111111111', region: 'us-east-1'},
    environment: 'prod',
    vpcId: 'vpc-12345',
    instanceType: 't4g.nano',
    enableCloudWatchMetrics: true,
    artifactBucket,
    artifactBucketName: HAPROXY_ARTIFACT_BUCKET_NAME,
  });
  const template = Template.fromStack(stack);
  const serializedTemplate = JSON.stringify(template.toJSON());
  assert.match(serializedTemplate, /parameter\/ctech\/prod\/lbalancer\/routes"/);
  assert.match(serializedTemplate, /parameter\/ctech\/prod\/lbalancer\/routes\/\*/);
  template.resourceCountIs('AWS::AutoScaling::AutoScalingGroup', 1);
  // Account, DFE, wallet, and poker API routes.
  template.resourceCountIs('AWS::SSM::Parameter', 4);
  template.hasResourceProperties('AWS::EC2::LaunchTemplate', {
    LaunchTemplateData: {
      CreditSpecification: {CpuCredits: 'standard'},
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
  template.resourceCountIs('AWS::Logs::MetricFilter', 9);
});
