#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import {
  DEFAULT_AWS_ACCOUNT,
  DEFAULT_AWS_REGION,
  DEFAULT_CLOUDFLARE_ZONE_ID,
  HAPROXY_ARTIFACT_BUCKET_NAME,
} from '../lib/constants';
import {ArtifactStack} from '../lib/artifact-stack';
import {LoadBalancerStack} from '../lib/load-balancer-stack';
import {Environment} from '../lib/types';

const app = new cdk.App();
const cfZoneId = process.env.CLOUDFLARE_ZONE_ID || DEFAULT_CLOUDFLARE_ZONE_ID;
const enableCloudWatchMetrics = (process.env.ENABLE_CLOUDWATCH_METRICS || 'true') === 'true';
const environment = (process.env.ENVIRONMENT ?? 'dev') as Environment;
const vpcId = process.env.CTECH_VPC_ID || 'vpc-0adfd86727d17445b';
const account = process.env.AWS_ACCOUNT ?? DEFAULT_AWS_ACCOUNT;
const region = process.env.AWS_REGION ?? DEFAULT_AWS_REGION;
const instanceType = process.env.INSTANCE_TYPE ?? 't4g.micro';

if (!['dev', 'stage', 'prod'].includes(environment)) {
  throw new Error(`ENVIRONMENT must be dev, stage, or prod; received ${environment}`);
}

if (!vpcId) {
  throw new Error('CTECH_VPC_ID is required (read /ctech/{env}/network/vpc-id from SSM)');
}

if (!['t4g.nano', 't4g.micro'].includes(instanceType)) {
  throw new Error('INSTANCE_TYPE must be t4g.micro or t4g.nano');
}

if (!/^[a-f0-9]{32}$/i.test(cfZoneId)) {
  throw new Error('CLOUDFLARE_ZONE_ID must be a 32-character hexadecimal Zone ID');
}

const cap = environment[0]!.toUpperCase() + environment.slice(1);
const artifactStack = new ArtifactStack(app, 'Ctech-LoadBalancerArtifacts', {
  env: {account, region},
  description: 'Content-addressed HAProxy ARM64 build artifacts',
});

new LoadBalancerStack(app, `Ctech-${cap}-LoadBalancer`, {
  env: {account, region},
  environment,
  vpcId,
  instanceType,
  cloudflareZoneId: cfZoneId,
  enableCloudWatchMetrics,
  artifactBucket: artifactStack.bucket,
  artifactBucketName: HAPROXY_ARTIFACT_BUCKET_NAME,
  description: `CTech IPv6-only HAProxy edge (${environment})`,
});

cdk.Tags.of(app).add('Project', 'ctech-lbalancer');
cdk.Tags.of(app).add('Environment', environment);
