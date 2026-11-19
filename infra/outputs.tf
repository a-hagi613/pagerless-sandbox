output "cluster_name" {
  description = "Name of the cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Cluster API endpoint, the only public endpoint the session exposes."
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group that carries control plane traffic."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node security group. Karpenter discovers it by tag; Amazon EKS attaches it to the system node group."
  value       = module.eks.node_security_group_id
}

output "karpenter_node_role_name" {
  description = "IAM role name that EC2NodeClass assigns to the instances Karpenter launches."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue the controller watches for Spot interruption notices."
  value       = module.karpenter.queue_name
}

output "karpenter_controller_role_arn" {
  description = "IAM role the Karpenter controller assumes through EKS Pod Identity."
  value       = module.karpenter.iam_role_arn
}

output "agent_role_arn" {
  description = "IAM role the pagerless-agent Job assumes through EKS Pod Identity."
  value       = aws_iam_role.agent_bedrock.arn
}
