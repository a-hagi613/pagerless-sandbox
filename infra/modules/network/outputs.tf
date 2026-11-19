output "vpc_id" {
  description = "Identifier of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets, in Availability Zone order."
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "Availability Zones the public subnets occupy, in the same order."
  value       = aws_subnet.public[*].availability_zone
}
