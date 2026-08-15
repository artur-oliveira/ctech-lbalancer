# Port of load-balancer-stack.ts:80-185 (InstanceRole + InstanceProfile).

data "aws_iam_policy_document" "instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid     = "GetLbalancerSecrets"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = concat([
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.routes}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.routes}/*",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.tls_certificate}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.tls_private_key}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.internal_tls_certificate}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.internal_tls_private_key}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.aop_ca}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.cloudflare_dns_token}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256}",
      ],
      var.enable_internal_m2m ? [
        "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.private_hosted_zone_id_parameter}",
      ] : [],
    )
  }

  dynamic "statement" {
    for_each = var.enable_internal_m2m ? [1] : []
    content {
      sid       = "UpdatePrivateLbalancerRecord"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["arn:aws:route53:::hostedzone/${data.aws_ssm_parameter.private_hosted_zone_id[0].value}"]
      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsRecordTypes"
        values   = ["A"]
      }
      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsActions"
        values   = ["UPSERT"]
      }
      condition {
        test     = "ForAllValues:StringLike"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = [local.internal_lbalancer_domain]
      }
    }
  }

  statement {
    sid     = "PublishOriginState"
    actions = ["ssm:PutParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.origin_ipv6}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter${local.ssm_paths.haproxy_artifact_sha256}",
    ]
  }

  statement {
    sid       = "HaproxyArtifactCache"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${data.aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid = "ReconcileDiscovery"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
    ]
    resources = ["*"]
  }

  # Auto-healing is route opt-in. SetInstanceHealth has no useful dynamic
  # resource scope because future routes can name ASGs without changing this policy.
  statement {
    sid       = "AutoHeal"
    actions   = ["autoscaling:SetInstanceHealth"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.environment}-ctech-lbalancer${var.resource_suffix}"
  role = aws_iam_role.instance.name

  lifecycle {
    create_before_destroy = true
  }
}
