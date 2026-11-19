output "state_bucket" {
  description = "Name of the state bucket, which must match `bucket` in infra/backend.tf."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}
