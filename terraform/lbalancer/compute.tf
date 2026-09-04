# Port of load-balancer-stack.ts:187-245 (LaunchTemplate + Asg) and
# lib/user-data.ts (buildUserData). Terraform's aws_launch_template supports
# ipv6_address_count/associate_public_ip_address natively — no CFN property
# override needed like the CDK version required.

locals {
  # Same template vars passed to every asset — templatefile() only errors on a
  # referenced var that's *missing*, not on unused extra keys, so one shared
  # map is safe across all three scripts even though each uses a subset.
  userdata_template_vars = {
    aws_region                          = var.aws_region
    environment                         = var.environment
    haproxy_version                     = local.haproxy_version
    haproxy_source_sha256               = local.haproxy_source_sha256
    routes_path                         = local.ssm_paths.routes
    origin_ipv6_path                    = local.ssm_paths.origin_ipv6
    tls_certificate_path                = local.ssm_paths.tls_certificate
    tls_private_key_path                = local.ssm_paths.tls_private_key
    internal_tls_certificate_path       = local.ssm_paths.internal_tls_certificate
    internal_tls_private_key_path       = local.ssm_paths.internal_tls_private_key
    aop_ca_path                         = local.ssm_paths.aop_ca
    cloudflare_token_path               = local.ssm_paths.cloudflare_dns_token
    cloudflare_zone_id                  = var.cloudflare_zone_id
    origin_domain                       = local.origin_domain
    enable_internal_m2m                 = tostring(var.enable_internal_m2m)
    vpc_ipv4_cidr                       = data.aws_vpc.this.cidr_block
    private_zone_id_path                = local.private_hosted_zone_id_parameter
    private_zone_name                   = local.private_zone_name
    internal_lbalancer_domain           = local.internal_lbalancer_domain
    enable_ssm_agent                    = tostring(var.enable_ssm_agent)
    enable_cloudwatch_logs              = tostring(var.enable_cloudwatch_logs)
    access_log_group                    = local.access_log_group_name
    haproxy_artifact_bucket             = data.aws_s3_bucket.artifacts.bucket
    haproxy_artifact_sha256_path        = local.ssm_paths.haproxy_artifact_sha256
    haproxy_artifact_sha256_alpine_path = local.ssm_paths.haproxy_artifact_sha256_alpine
    ec2_scripts_bucket                  = data.aws_ssm_parameter.ec2_scripts_bucket.value
    ec2_scripts_version                 = data.aws_ssm_parameter.ec2_scripts_version.value
    ec2_scripts_alpine_bucket           = var.os_family == "alpine" ? data.aws_ssm_parameter.ec2_scripts_alpine_bucket[0].value : ""
    ec2_scripts_alpine_version          = var.os_family == "alpine" ? data.aws_ssm_parameter.ec2_scripts_alpine_version[0].value : ""
  }

  # local.user_data below only ever references these three locals by name —
  # it needs no os_family branch of its own. Alpine's baked-in ctech-userdata
  # OpenRC service (ctech-cdk's Packer pipeline) fetches and runs this same
  # raw #!/bin/bash payload directly via IMDS, bypassing cloud-init exactly
  # the way ValkeyStackV2's user data already does on that AMI.
  reconcile_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/reconcile-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/reconcile.sh.tftpl", local.userdata_template_vars)

  refresh_cloudflare_ips_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/refresh-cloudflare-ips-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/refresh-cloudflare-ips.sh.tftpl", local.userdata_template_vars)

  bootstrap_sh = var.os_family == "alpine" ? templatefile("${path.module}/../../assets/bootstrap-alpine.sh.tftpl", local.userdata_template_vars) : templatefile("${path.module}/../../assets/bootstrap.sh.tftpl", local.userdata_template_vars)

  runtime_scripts = {
    "reconcile.sh"              = local.reconcile_sh
    "refresh-cloudflare-ips.sh" = local.refresh_cloudflare_ips_sh
    "bootstrap.sh"              = local.bootstrap_sh
  }

  # Keep user data far below EC2's 16 KiB decoded limit. The rendered scripts
  # are immutable, content-addressed S3 objects; referencing their keys here
  # also creates the dependency that uploads them before an instance can boot.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail
    mkdir -p /opt/ctech-lbalancer /etc/haproxy/tls /var/lib/haproxy /var/log/haproxy

    ${join("\n", [for name in sort(keys(local.runtime_scripts)) : var.os_family == "alpine" ?
    "ctech-ec2-agent s3-cp -bucket '${data.aws_s3_bucket.artifacts.bucket}' -key '${aws_s3_object.runtime_script[name].key}' -dest '/opt/ctech-lbalancer/${name}' >/dev/null" :
    "aws s3 cp 's3://${data.aws_s3_bucket.artifacts.bucket}/${aws_s3_object.runtime_script[name].key}' '/opt/ctech-lbalancer/${name}' >/dev/null"
])}
    chmod 0750 /opt/ctech-lbalancer/*.sh

    /opt/ctech-lbalancer/bootstrap.sh
    EOF
)
}

resource "aws_s3_object" "runtime_script" {
  for_each = local.runtime_scripts

  bucket                 = data.aws_s3_bucket.artifacts.bucket
  key                    = "runtime/${var.environment}/${sha256(each.value)}/${each.key}"
  content                = each.value
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
  source_hash            = sha256(each.value)
}

check "ec2_user_data_size" {
  assert {
    condition     = length(base64decode(local.user_data)) <= 16384
    error_message = "Decoded EC2 user data exceeds the 16 KiB API limit; keep runtime scripts in content-addressed S3 objects."
  }
}

resource "aws_launch_template" "this" {
  name          = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
  instance_type = var.instance_type

  image_id = var.os_family == "alpine" ? data.aws_ssm_parameter.alpine_arm64_ami[0].value : data.aws_ssm_parameter.al2023_arm64_ami.value

  # T4g has no launch credits; "standard" is the CPU-credits equivalent of
  # CDK's ec2.CpuCredits.STANDARD.
  credit_specification {
    cpu_credits = "standard"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.os_family == "alpine" ? 1 : 4
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  metadata_options {
    http_tokens = "required"
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    ipv6_address_count          = 1
    security_groups = [
      data.aws_ssm_parameter.edge_security_group_id.value,
      aws_security_group.ipv6_egress.id,
    ]
  }

  user_data = local.user_data

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
      Environment = var.environment
      Project     = "ctech-lbalancer"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
      Environment = var.environment
      Project     = "ctech-lbalancer"
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  # Instances need Parameter Store, Cloudflare-DNS inputs and log-stream
  # permissions on their very first boot, not eventually after IAM converges.
  depends_on = [
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm_managed_instance_core,
  ]
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
  vpc_zone_identifier = local.t4g_public_subnet_ids
  min_size            = 1
  # +1 over min_size: gives CapacityRebalance headroom to launch the
  # replacement before terminating the spot-interrupted instance instead of
  # waiting for it to go down first.
  max_size                  = 2
  health_check_type         = "EC2"
  health_check_grace_period = 600
  capacity_rebalance        = true

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = aws_launch_template.this.latest_version
      }
    }
    instances_distribution {
      spot_allocation_strategy                 = "price-capacity-optimized"
      on_demand_percentage_above_base_capacity = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "ctech-lbalancer"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  # ctech-cdk's NetworkStack tags subnets with the standard CDK
  # aws-cdk:subnet-type marker — more reliable than matching on Name.
  tags = {
    "aws-cdk:subnet-type" = "Public"
  }
}

# Keep the VPC's public subnet in us-east-1e available to other workloads, but
# exclude it from this t4g ASG because that instance family is unavailable there.
data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  t4g_public_subnet_ids = [
    for subnet in data.aws_subnet.public : subnet.id
    if subnet.availability_zone != "us-east-1e"
  ]
}

# The shared bootstrap scripts published by ctech-cdk's Ec2ScriptsStack. The
# version is the content hash of its assets/ec2 directory and is also the S3 key
# prefix, so a script edit versions this launch template.
data "aws_ssm_parameter" "ec2_scripts_bucket" {
  name = "/ctech/${var.environment}/ec2-scripts/bucket"
}

data "aws_ssm_parameter" "ec2_scripts_version" {
  name = "/ctech/${var.environment}/ec2-scripts/version"
}

data "aws_ssm_parameter" "al2023_arm64_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-minimal-kernel-default-arm64"
}
