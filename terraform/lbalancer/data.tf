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

# ctech-cdk's Alpine ARM64 AMI and its published Alpine script library —
# only fetched when this environment actually opts into os_family=alpine, so
# an environment that has never run the Alpine AMI/script pipeline doesn't
# fail terraform plan/apply for an unrelated SSM parameter it will never use.
data "aws_ssm_parameter" "alpine_arm64_ami" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ami/alpine/arm64"
}

data "aws_ssm_parameter" "ec2_scripts_alpine_bucket" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ec2-scripts-alpine/bucket"
}

data "aws_ssm_parameter" "ec2_scripts_alpine_version" {
  count = var.os_family == "alpine" ? 1 : 0
  name  = "/ctech/${var.environment}/ec2-scripts-alpine/version"
}
