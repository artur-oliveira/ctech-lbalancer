import {Environment, RouteRegistration} from './types';

export const DEFAULT_AWS_ACCOUNT = '868899309401';
export const DEFAULT_AWS_REGION = 'us-east-1';
export const BASE_DOMAIN = 'aoctech.app';

// HAProxy 3.4 is the current community LTS line (supported through 2031-Q2).
// Keep patch updates explicit so
// a replacement instance always installs an audited, reproducible binary.
export const HAPROXY_VERSION = '3.4.3';
export const HAPROXY_SHA256 = '7fa666d36d198275999e2a68dda44d3d37960f2f7aed3a595fb811f4fd0515b5';

export const ssmPaths = (environment: Environment) => ({
  edgeSecurityGroupId: `/ctech/${environment}/network/alb-sg-id`,
  routes: `/ctech/${environment}/lbalancer/routes`,
  originIpv6: `/ctech/${environment}/lbalancer/origin-ipv6`,
  tlsCertificate: `/ctech/${environment}/lbalancer/tls/origin-certificate`,
  tlsPrivateKey: `/ctech/${environment}/lbalancer/tls/origin-private-key`,
  aopCa: `/ctech/${environment}/lbalancer/tls/aop-ca`,
  cloudflareDnsToken: '/ctech/global/cloudflare/dns-api-token',
});

export function domainForEnv(environment: Environment, prefix: string): string {
  return environment === 'prod'
    ? `${prefix}.${BASE_DOMAIN}`
    : `${prefix}-${environment}.${BASE_DOMAIN}`;
}

export function originDomainForEnv(environment: Environment): string {
  return domainForEnv(environment, 'origin');
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
      asg: `${environment}-ctech-account-v2`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200],
      autoHeal: true,
    },
    dfe: {
      hostname: domainForEnv(environment, 'dfe-api'),
      asg: `${environment}-ctech-dfe-v2-api`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
    wallet: {
      hostname: domainForEnv(environment, 'wallet-api'),
      asg: `${environment}-ctech-wallet-v2-api`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
    poker: {
      hostname: domainForEnv(environment, 'poker-api'),
      asg: `${environment}-ctech-poker-api`,
      port: 8080,
      healthPath: '/v1.0/health-check',
      healthyStatuses: [200, 207],
      autoHeal: true,
    },
  };
}
