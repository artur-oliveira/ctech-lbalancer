import {gzipSync} from 'node:zlib';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {Token} from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import {HAPROXY_SOURCE_SHA256, HAPROXY_VERSION, originDomainForEnv, ssmPaths} from './constants';
import {Environment} from './types';

export interface LoadBalancerUserDataProps {
  environment: Environment;
  region: string;
  cloudflareZoneId?: string;
  enableCloudWatchMetrics: boolean;
  accessLogGroupName: string;
  artifactBucketName: string;
}

function asset(name: string): string {
  return readFileSync(join(__dirname, '..', 'assets', name), 'utf8');
}

function installCompressed(userData: ec2.UserData, path: string, contents: string, mode: string): void {
  const encoded = gzipSync(contents, {level: 9}).toString('base64');
  userData.addCommands(
    `echo '${encoded}' | base64 -d | gzip -d > ${path}`,
    `chmod ${mode} ${path}`,
  );
}

export function buildUserData(props: LoadBalancerUserDataProps): ec2.UserData {
  if (Token.isUnresolved(props.artifactBucketName)) {
    throw new Error('artifactBucketName must be a physical name, not a CDK token');
  }
  if (Token.isUnresolved(props.accessLogGroupName)) {
    throw new Error('accessLogGroupName must be a physical name, not a CDK token');
  }
  const paths = ssmPaths(props.environment);
  const substitutions: Record<string, string> = {
    '__AWS_REGION__': props.region,
    '__ENVIRONMENT__': props.environment,
    '__HAPROXY_VERSION__': HAPROXY_VERSION,
    '__HAPROXY_SOURCE_SHA256__': HAPROXY_SOURCE_SHA256,
    '__ROUTES_PATH__': paths.routes,
    '__ORIGIN_IPV6_PATH__': paths.originIpv6,
    '__TLS_CERTIFICATE_PATH__': paths.tlsCertificate,
    '__TLS_PRIVATE_KEY_PATH__': paths.tlsPrivateKey,
    '__AOP_CA_PATH__': paths.aopCa,
    '__CLOUDFLARE_TOKEN_PATH__': paths.cloudflareDnsToken,
    '__CLOUDFLARE_ZONE_ID__': props.cloudflareZoneId ?? '',
    '__ORIGIN_DOMAIN__': originDomainForEnv(props.environment),
    '__ENABLE_CLOUDWATCH__': props.enableCloudWatchMetrics ? 'true' : 'false',
    '__ACCESS_LOG_GROUP__': props.accessLogGroupName,
    '__HAPROXY_ARTIFACT_BUCKET__': props.artifactBucketName,
    '__HAPROXY_ARTIFACT_SHA256_PATH__': paths.haproxyArtifactSha256,
  };

  const replace = (input: string): string => Object.entries(substitutions)
    .reduce((value, [search, replacement]) => value.replaceAll(search, replacement), input);

  const userData = ec2.UserData.forLinux();
  userData.addCommands(
    'set -euxo pipefail',
    'mkdir -p /opt/ctech-lbalancer /etc/haproxy/tls /var/lib/haproxy /var/log/haproxy',
  );
  installCompressed(userData, '/opt/ctech-lbalancer/reconcile.sh', replace(asset('reconcile.sh')), '0750');
  installCompressed(userData, '/opt/ctech-lbalancer/refresh-cloudflare-ips.sh', replace(asset('refresh-cloudflare-ips.sh')), '0750');
  installCompressed(userData, '/opt/ctech-lbalancer/bootstrap.sh', replace(asset('bootstrap.sh')), '0750');
  userData.addCommands('/opt/ctech-lbalancer/bootstrap.sh');
  return userData;
}
