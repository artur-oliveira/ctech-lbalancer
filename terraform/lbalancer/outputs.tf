output "autoscaling_group_name" {
  value = aws_autoscaling_group.this.name
}

output "origin_hostname" {
  value = local.origin_domain
}

output "origin_ipv6_parameter" {
  value = local.ssm_paths.origin_ipv6
}

output "route_parameter_prefix" {
  value = local.ssm_paths.routes
}

output "haproxy_version" {
  value = local.haproxy_version
}

output "haproxy_artifact_bucket" {
  value = data.aws_s3_bucket.artifacts.bucket
}

output "haproxy_artifact_hash_parameter" {
  value = local.ssm_paths.haproxy_artifact_sha256
}

output "cloudwatch_metrics_enabled" {
  value = var.enable_cloudwatch_metrics
}

output "internal_m2m_enabled" {
  value = var.enable_internal_m2m
}

output "internal_lbalancer_hostname" {
  value = var.enable_internal_m2m ? local.internal_lbalancer_domain : null
}
