output "plan_role_arn" {
  description = "Role the pull request plan job assumes."
  value       = aws_iam_role.plan.arn
}

output "destroy_role_arn" {
  description = "Role the nightly teardown assumes."
  value       = aws_iam_role.destroy.arn
}

output "github_oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider both roles trust."
  value       = aws_iam_openid_connect_provider.github.arn
}
