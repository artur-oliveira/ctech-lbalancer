#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import {DEFAULT_AWS_ACCOUNT, DEFAULT_AWS_REGION} from '../lib/constants';
import {LoadBalancerStack} from '../lib/load-balancer-stack';
import {Environment} from '../lib/types';

const app = new cdk.App();
const cfZoneId = process.env.CLOUDFLARE_ZONE_ID || '250cb2c0-86f1-4dba-8e67-38331ffc8fb3';
const cloudwatchEnabled = process.env.ENABLE_CLOUDWATCH_METRICS || 'true';
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

const cap = environment[0]!.toUpperCase() + environment.slice(1);

new LoadBalancerStack(app, `Ctech-${cap}-LoadBalancer`, {
  env: {account, region},
  environment,
  vpcId,
  instanceType,
  cloudflareZoneId: cfZoneId,
  enableCloudWatchMetrics: cloudwatchEnabled === 'true',
  description: `CTech IPv6-only HAProxy edge (${environment})`,
});

cdk.Tags.of(app).add('Project', 'ctech-lbalancer');
cdk.Tags.of(app).add('Environment', environment);
