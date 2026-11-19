# Karpenter discovers the network it may launch into by tag, on the subnets and
# on the security group, rather than by identifier passed to its configuration.
# The tags live here so that the network module stays a plain VPC.
resource "aws_ec2_tag" "public_subnet_karpenter" {
  count = var.availability_zone_count

  resource_id = module.network.public_subnet_ids[count.index]
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
