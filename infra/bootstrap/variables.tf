variable "aws_account_id" {
  description = "The only AWS account this bootstrap may create the bucket in."
  type        = string
  default     = "207567775100"
}

variable "aws_region" {
  description = "Region of the state bucket. It must match the stack's backend configuration."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the state bucket. It must match `bucket` in infra/backend.tf."
  type        = string
  default     = "pagerless-terraform-state-207567775100"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "The bucket name must be a valid S3 bucket name."
  }
}

variable "noncurrent_version_expiry_days" {
  description = "Days a superseded state version is kept before it is deleted."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiry_days >= 7
    error_message = "Keep superseded state versions for at least seven days."
  }
}
