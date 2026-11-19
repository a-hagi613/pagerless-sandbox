variable "aws_account_id" {
  description = "The only AWS account this configuration may change."
  type        = string
  default     = "207567775100"
}

variable "aws_region" {
  description = "Region of the state bucket and of every session the workflows touch."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "State bucket created by infra/bootstrap. Both CI roles read the stack's state from it."
  type        = string
  default     = "pagerless-terraform-state-207567775100"
}

variable "github_repository" {
  description = "The only repository whose workflows may assume either role."
  type        = string
  default     = "a-hagi613/pagerless-sandbox"
}

variable "github_repository_owner_id" {
  description = "Immutable owner ID of that repository, from the GitHub API. The subject claim of a repository created after 2026-07-15 includes it."
  type        = string
  default     = "92589940"
}

variable "github_repository_id" {
  description = "Immutable ID of that repository, from the GitHub API."
  type        = string
  default     = "1460616727"
}

variable "plan_role_name" {
  description = "Role the pull request plan job assumes."
  type        = string
  default     = "pagerless-github-plan"
}

variable "destroy_role_name" {
  description = "Role the nightly teardown assumes."
  type        = string
  default     = "pagerless-github-destroy"
}
