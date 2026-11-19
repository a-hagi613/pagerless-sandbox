variable "name" {
  description = "Prefix of every resource name in the network."
  type        = string
}

variable "cidr_block" {
  description = "CIDR block of the VPC."
  type        = string
}

variable "availability_zone_count" {
  description = "Number of public subnets to create, one per Availability Zone."
  type        = number
}
