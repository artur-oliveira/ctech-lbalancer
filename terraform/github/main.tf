# The account-wide GitHub OIDC provider is owned by ctech-cdk and published in
# SSM. This root follows ctech-billing's trust pattern, including GitHub's
# immutable repository-ID subject spelling, but grants only artifact publishing.
data "aws_ssm_parameter" "oidc_provider_arn" {
  name = "/ctech/global/oidc/provider-arn"
}

locals {
  github_owner = split("/", var.github_repo)[0]
  github_name  = split("/", var.github_repo)[1]

  publish_subjects = flatten([
    for branch in var.publish_branches : [
      "repo:${var.github_repo}:ref:refs/heads/${branch}",
      "repo:${local.github_owner}@*/${local.github_name}@*:ref:refs/heads/${branch}",
    ]
  ])
}

data "aws_iam_policy_document" "assume_haproxy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.oidc_provider_arn.value]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.publish_subjects
    }
  }
}

resource "aws_iam_role" "haproxy" {
  name                 = "ctech-lbalancer-gha-haproxy"
  description          = "Build and publish pinned HAProxy ARM64 artifacts"
  assume_role_policy   = data.aws_iam_policy_document.assume_haproxy.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "haproxy" {
  statement {
    sid = "PublishArtifact"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::ctech-lbalancer-artifacts/*"]
  }

  statement {
    sid = "PublishAlpinePointer"
    actions = [
      "ssm:GetParameter",
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account}:parameter/ctech/global/lbalancer/haproxy/*/alpine-arm64/artifact-sha256",
    ]
  }
}

resource "aws_iam_role_policy" "haproxy" {
  name   = "publish"
  role   = aws_iam_role.haproxy.id
  policy = data.aws_iam_policy_document.haproxy.json
}
