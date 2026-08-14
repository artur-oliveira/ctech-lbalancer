import {Environment, RouteRegistration} from './types';

export const DEFAULT_AWS_ACCOUNT = '868899309401';
export const DEFAULT_AWS_REGION = 'us-east-1';
export const BASE_DOMAIN = 'aoctech.app';
export const PRIVATE_ZONE_NAME = `internal.${BASE_DOMAIN}`;
export const PRIVATE_HOSTED_ZONE_ID_PARAMETER = '/ctech/global/dns/private-hosted-zone-id';
export const DEFAULT_CLOUDFLARE_ZONE_ID = 'bdfaf9265eacff459d2a6c45e4f99664';

// HAProxy 3.4 is the current community LTS line (supported through 2031-Q2).
// Keep patch updates explicit so
// a replacement instance always installs an audited, reproducible binary.
export const HAPROXY_VERSION = '3.4.3';
export const HAPROXY_ARTIFACT_BUCKET_NAME = 'ctech-lbalancer-artifacts';
export const HAPROXY_SOURCE_SHA256 = '7fa666d36d198275999e2a68dda44d3d37960f2f7aed3a595fb811f4fd0515b5';

export const ssmPaths = (environment: Environment) => ({
  edgeSecurityGroupId: `/ctech/${environment}/network/alb-sg-id`,
  routes: `/ctech/${environment}/lbalancer/routes`,
  originIpv6: `/ctech/${environment}/lbalancer/origin-ipv6`,
  tlsCertificate: `/ctech/${environment}/lbalancer/tls/origin-certificate`,
  tlsPrivateKey: `/ctech/${environment}/lbalancer/tls/origin-private-key`,
  internalTlsCertificate: `/ctech/${environment}/lbalancer/tls/internal-certificate`,
  internalTlsPrivateKey: `/ctech/${environment}/lbalancer/tls/internal-private-key`,
  aopCa: `/ctech/${environment}/lbalancer/tls/aop-ca`,
  cloudflareDnsToken: '/ctech/global/cloudflare/dns-api-token',
  haproxyArtifactSha256: `/ctech/global/lbalancer/haproxy/${HAPROXY_VERSION}/al2023-arm64/artifact-sha256`,
});

export function domainForEnv(environment: Environment, prefix: string): string {
  return environment === 'prod'
    ? `${prefix}.${BASE_DOMAIN}`
    : `${prefix}-${environment}.${BASE_DOMAIN}`;
}

export function originDomainForEnv(environment: Environment): string {
  return domainForEnv(environment, 'origin');
}

export function internalLoadBalancerDomain(): string {
  return `lbalancer.${PRIVATE_ZONE_NAME}`;
}

export function internalServiceDomain(environment: Environment, prefix: string): string {
  return environment === 'prod'
    ? `${prefix}.${PRIVATE_ZONE_NAME}`
    : `${prefix}-${environment}.${PRIVATE_ZONE_NAME}`;
}

/**
 * These are API origins in the current repositories. The UI names
 * (poker/accounts/wallet) still belong to CloudFront and must not be repointed
 * until their S3 behaviours are intentionally migrated as well.
 */
export function defaultRoutes(environment: Environment): Record<string, RouteRegistration> {
  return {
    account: {
      hostname: domainForEnv(environment, 'accounts-api'),
      internalHostname: internalServiceDomain(environment, 'accounts'),
      asg: `${environment}-ctech-account`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200],
      autoHeal: true,
    },
    dfe: {
      hostname: domainForEnv(environment, 'dfe-api'),
      internalHostname: internalServiceDomain(environment, 'dfe'),
      asg: `${environment}-ctech-dfe`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
    wallet: {
      hostname: domainForEnv(environment, 'wallet-api'),
      internalHostname: internalServiceDomain(environment, 'wallet'),
      asg: `${environment}-ctech-wallet`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
    poker: {
      hostname: domainForEnv(environment, 'poker-api'),
      internalHostname: internalServiceDomain(environment, 'poker'),
      asg: `${environment}-ctech-poker`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
  };
}
