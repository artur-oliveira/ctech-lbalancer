output "haproxy_artifact_role_arn" {
  description = "Role assumed by .github/workflows/haproxy-artifact.yml."
  value       = aws_iam_role.haproxy.arn
}
