data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_ssm_parameter" "edge_security_group_id" {
  name = local.ssm_paths.edge_security_group_id
}

data "aws_ssm_parameter" "private_hosted_zone_id" {
  count = var.enable_internal_m2m ? 1 : 0
  name  = local.private_hosted_zone_id_parameter
}

data "aws_route53_zone" "private" {
  count   = var.enable_internal_m2m ? 1 : 0
  zone_id = data.aws_ssm_parameter.private_hosted_zone_id[0].value
}

data "aws_s3_bucket" "artifacts" {
  bucket = local.haproxy_artifact_bucket_name
}
