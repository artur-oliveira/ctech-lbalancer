# Port of lib/constants.ts and lib/types.ts.

locals {
  base_domain                      = "aoctech.app"
  private_zone_name                = "internal.${local.base_domain}"
  private_hosted_zone_id_parameter = "/ctech/global/dns/private-hosted-zone-id"
  haproxy_version                  = "3.4.3"
  haproxy_artifact_bucket_name     = "ctech-lbalancer-artifacts"
  haproxy_source_sha256            = "7fa666d36d198275999e2a68dda44d3d37960f2f7aed3a595fb811f4fd0515b5"

  ssm_paths = {
    edge_security_group_id   = "/ctech/${var.environment}/network/alb-sg-id"
    routes                   = "/ctech/${var.environment}/lbalancer/routes"
    origin_ipv6              = "/ctech/${var.environment}/lbalancer/origin-ipv6"
    tls_certificate          = "/ctech/${var.environment}/lbalancer/tls/origin-certificate"
    tls_private_key          = "/ctech/${var.environment}/lbalancer/tls/origin-private-key"
    internal_tls_certificate = "/ctech/${var.environment}/lbalancer/tls/internal-certificate"
    internal_tls_private_key = "/ctech/${var.environment}/lbalancer/tls/internal-private-key"
    aop_ca                   = "/ctech/${var.environment}/lbalancer/tls/aop-ca"
    cloudflare_dns_token     = "/ctech/global/cloudflare/dns-api-token"
    haproxy_artifact_sha256  = "/ctech/global/lbalancer/haproxy/${local.haproxy_version}/al2023-arm64/artifact-sha256"
  }

  # domainForEnv(env, prefix)
  domain_for_env = { for prefix in ["origin", "accounts-api", "dfe-api", "wallet-api", "poker-api"] :
    prefix => var.environment == "prod" ? "${prefix}.${local.base_domain}" : "${prefix}-${var.environment}.${local.base_domain}"
  }
  origin_domain = local.domain_for_env["origin"]

  internal_lbalancer_domain = "lbalancer.${local.private_zone_name}"

  # internalServiceDomain(env, prefix)
  internal_service_domain = { for prefix in ["accounts", "dfe", "wallet", "poker"] :
    prefix => var.environment == "prod" ? "${prefix}.${local.private_zone_name}" : "${prefix}-${var.environment}.${local.private_zone_name}"
  }

  # Port of defaultRoutes(environment) in constants.ts.
  default_routes = {
    account = {
      hostname          = local.domain_for_env["accounts-api"]
      internal_hostname = local.internal_service_domain["accounts"]
      asg               = "${var.environment}-ctech-account"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200]
      auto_heal         = true
    }
    dfe = {
      hostname          = local.domain_for_env["dfe-api"]
      internal_hostname = local.internal_service_domain["dfe"]
      asg               = "${var.environment}-ctech-dfe"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200, 207]
      auto_heal         = true
    }
    wallet = {
      hostname          = local.domain_for_env["wallet-api"]
      internal_hostname = local.internal_service_domain["wallet"]
      asg               = "${var.environment}-ctech-wallet"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200, 207]
      auto_heal         = true
    }
    poker = {
      hostname          = local.domain_for_env["poker-api"]
      internal_hostname = local.internal_service_domain["poker"]
      asg               = "${var.environment}-ctech-poker"
      port              = 8080
      health_path       = "/v1.0/health-check"
      healthy_statuses  = [200, 207]
      auto_heal         = true
    }
  }

  access_log_group_name = "/ctech-lbalancer/${var.environment}/access${var.resource_suffix}"

  status_metric_patterns = {
    HTTP2XX = "{ ($.status >= 200) && ($.status < 300) }"
    HTTP3XX = "{ ($.status >= 300) && ($.status < 400) }"
    HTTP4XX = "{ ($.status >= 400) && ($.status < 500) }"
    HTTP5XX = "{ $.status >= 500 }"
  }

  # [pattern, metric_value, unit]
  request_metric_patterns = {
    RequestTotal                       = { pattern = "{ $.status = * }", value = "1", unit = "Count" }
    TotalLatencyMilliseconds           = { pattern = "{ $.total_time_ms = * }", value = "$.total_time_ms", unit = "Milliseconds" }
    QueueLatencyMilliseconds           = { pattern = "{ $.queue_time_ms = * }", value = "$.queue_time_ms", unit = "Milliseconds" }
    BackendConnectLatencyMilliseconds  = { pattern = "{ $.backend_connect_time_ms = * }", value = "$.backend_connect_time_ms", unit = "Milliseconds" }
    BackendResponseLatencyMilliseconds = { pattern = "{ $.backend_response_time_ms = * }", value = "$.backend_response_time_ms", unit = "Milliseconds" }
  }
}
