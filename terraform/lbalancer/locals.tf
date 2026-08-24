# Port of lib/constants.ts and lib/types.ts.

locals {
  haproxy_build                    = jsondecode(file("${path.module}/../../build/haproxy.json"))
  base_domain                      = "aoctech.app"
  private_zone_name                = "internal.${local.base_domain}"
  private_hosted_zone_id_parameter = "/ctech/global/dns/private-hosted-zone-id"
  haproxy_version                  = local.haproxy_build.version
  haproxy_artifact_bucket_name     = "ctech-lbalancer-artifacts"
  haproxy_source_sha256            = local.haproxy_build.source_sha256

  ssm_paths = {
    edge_security_group_id         = "/ctech/${var.environment}/network/alb-sg-id"
    routes                         = "/ctech/${var.environment}/lbalancer/routes"
    origin_ipv6                    = "/ctech/${var.environment}/lbalancer/origin-ipv6"
    tls_certificate                = "/ctech/${var.environment}/lbalancer/tls/origin-certificate"
    tls_private_key                = "/ctech/${var.environment}/lbalancer/tls/origin-private-key"
    internal_tls_certificate       = "/ctech/${var.environment}/lbalancer/tls/internal-certificate"
    internal_tls_private_key       = "/ctech/${var.environment}/lbalancer/tls/internal-private-key"
    aop_ca                         = "/ctech/${var.environment}/lbalancer/tls/aop-ca"
    cloudflare_dns_token           = "/ctech/global/cloudflare/dns-api-token"
    haproxy_artifact_sha256        = "/ctech/global/lbalancer/haproxy/${local.haproxy_version}/al2023-arm64/artifact-sha256"
    haproxy_artifact_sha256_alpine = "/ctech/global/lbalancer/haproxy/${local.haproxy_version}/alpine-arm64/artifact-sha256"
  }

  # domainForEnv(env, prefix)
  domain_for_env = { for prefix in [
    "origin", "accounts-api", "dfe-api", "wallet-api", "poker-api", "billing-api",
    "accounts", "dfe", "wallet", "poker", "billing",
    ] :
    prefix => var.environment == "prod" ? "${prefix}.${local.base_domain}" : "${prefix}-${var.environment}.${local.base_domain}"
  }
  origin_domain = local.domain_for_env["origin"]

  # Existing SPA hosts allowed to send credentialed cross-origin requests to
  # accounts-api's /token endpoint.
  spa_origins = [
    local.domain_for_env["dfe"],
    local.domain_for_env["wallet"],
    local.domain_for_env["accounts"],
    local.domain_for_env["billing"],
    local.domain_for_env["poker"],
  ]

  internal_lbalancer_domain = "lbalancer.${local.private_zone_name}"

  # internalServiceDomain(env, prefix)
  internal_service_domain = { for prefix in ["accounts", "dfe", "wallet", "poker", "billing"] :
    prefix => var.environment == "prod" ? "${prefix}.${local.private_zone_name}" : "${prefix}-${var.environment}.${local.private_zone_name}"
  }

  # Port of defaultRoutes(environment) in constants.ts.
  default_routes = {
    account = {
      hostname          = local.domain_for_env["accounts-api"]
      internal_hostname = local.internal_service_domain["accounts"]
      # /token is called cross-origin by every existing SPA; allowlist them
      # by name rather than reflecting any Origin.
      cors_origin      = local.spa_origins
      asg              = "${var.environment}-ctech-account"
      port             = 8080
      health_path      = "/v1.0/health-check"
      healthy_statuses = [200]
      auto_heal        = true
    }
    dfe = {
      hostname          = local.domain_for_env["dfe-api"]
      internal_hostname = local.internal_service_domain["dfe"]
      cors_origin       = local.domain_for_env["dfe"]
      asg               = "${var.environment}-ctech-dfe"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200]
      auto_heal         = true
    }
    wallet = {
      hostname          = local.domain_for_env["wallet-api"]
      internal_hostname = local.internal_service_domain["wallet"]
      cors_origin       = local.domain_for_env["wallet"]
      asg               = "${var.environment}-ctech-wallet"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200]
      auto_heal         = true
    }
    poker = {
      hostname          = local.domain_for_env["poker-api"]
      internal_hostname = local.internal_service_domain["poker"]
      cors_origin       = local.domain_for_env["poker"]
      asg               = "${var.environment}-ctech-poker"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200]
      auto_heal         = true
    }
    billing = {
      hostname          = local.domain_for_env["billing-api"]
      internal_hostname = local.internal_service_domain["billing"]
      cors_origin       = local.domain_for_env["billing"]
      asg               = "${var.environment}-ctech-billing"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200]
      auto_heal         = true
    }
  }

}
