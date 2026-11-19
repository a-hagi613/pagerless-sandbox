# Karpenter's controller identity, interruption queue and node role.
#
# The module creates the IAM role and its least-privilege policy, the EKS Pod
# Identity association for kube-system/karpenter, the SQS queue and EventBridge
# rules that carry Spot interruption notices, the node role, and the access entry
# that lets that role join the cluster. The chart itself is installed by
# `make cloud-up`, which also applies the NodePool and EC2NodeClass in
# platform/cloud/karpenter.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.30.2"

  cluster_name = module.eks.cluster_name
  namespace    = "kube-system"

  iam_role_name = "${var.cluster_name}-karpenter"

  # The controller may assume the role only from this cluster.
  iam_role_source_arn_condition = true

  # The interrupt queue is what makes a Spot reclaim a graceful drain rather
  # than a deleted node.
  enable_spot_termination = true
  queue_name              = "${var.cluster_name}-karpenter"

  create_node_iam_role          = true
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  # Outbound Systems Manager Session Manager gives interactive shell access to
  # Karpenter-provisioned nodes without an SSH key or an inbound port-22 rule on
  # the node security group.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Name = "${var.cluster_name}-karpenter"
  }
}
