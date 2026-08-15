# Port of load-balancer-stack.ts:247-263 (default route SSM parameters + private CNAMEs).

resource "aws_ssm_parameter" "route" {
  for_each = var.manage_routes ? local.default_routes : {}
  name     = "${local.ssm_paths.routes}/${each.key}"
  type     = "String"
  tier     = "Standard"
  value = jsonencode({
    hostname         = each.value.hostname
    internalHostname = each.value.internal_hostname
    asg              = each.value.asg
    port             = each.value.port
    healthPath       = each.value.health_path
    healthyStatuses  = each.value.healthy_statuses
    autoHeal         = each.value.auto_heal
  })
}

resource "aws_route53_record" "route_internal_alias" {
  for_each = (var.enable_internal_m2m && var.manage_routes) ? local.default_routes : {}
  zone_id  = data.aws_route53_zone.private[0].zone_id
  name     = each.value.internal_hostname
  type     = "CNAME"
  ttl      = 30
  records  = [local.internal_lbalancer_domain]
}
