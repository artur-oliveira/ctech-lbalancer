resource "aws_cloudwatch_log_group" "access" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = local.access_log_group_name
  retention_in_days = var.environment == "prod" ? 30 : 7

  lifecycle {
    create_before_destroy = true
  }
}
