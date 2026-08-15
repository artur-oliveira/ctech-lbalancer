# Port of load-balancer-stack.ts:149-180 (AccessLogs + STATUS_PATTERNS + REQUEST_METRICS).
# Note: CDK's removalPolicy (RETAIN in prod, DESTROY otherwise) has no direct
# Terraform equivalent (prevent_destroy can't be conditioned on a variable) —
# out of scope for this port, revisit if it matters operationally.

resource "aws_cloudwatch_log_group" "access" {
  name              = local.access_log_group_name
  retention_in_days = 7

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_metric_filter" "status" {
  for_each       = var.enable_cloudwatch_metrics ? local.status_metric_patterns : {}
  name           = "${each.key}Filter"
  log_group_name = aws_cloudwatch_log_group.access.name
  pattern        = each.value

  metric_transformation {
    name          = each.key
    namespace     = "CtechLoadBalancer/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "requests" {
  for_each       = var.enable_cloudwatch_metrics ? local.request_metric_patterns : {}
  name           = "${each.key}Filter"
  log_group_name = aws_cloudwatch_log_group.access.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "CtechLoadBalancer/${var.environment}"
    value     = each.value.value
    unit      = each.value.unit
  }
}

resource "aws_iam_role_policy" "access_logs" {
  count = var.enable_cloudwatch_metrics ? 1 : 0
  name  = "${var.environment}-ctech-lbalancer-access-logs${var.resource_suffix}"
  role  = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.access.arn}:*"
    }]
  })

  lifecycle {
    create_before_destroy = true
  }
}
