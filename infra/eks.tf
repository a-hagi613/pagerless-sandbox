# The cluster the cloud session runs on (ADR-0009, ADR-0010).
#
# One small Spot managed node group carries the system pods, and Karpenter adds
# x86_64 Spot capacity for everything else. Amazon EKS Auto Mode is deliberately
# not enabled: it would add a per-cluster charge and hide the node provisioning
# that this ticket exists to show.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.public_subnet_ids

  # The API endpoint is the only public endpoint the session exposes. Nodes and
  # the operator reach it over the internet gateway; nothing reaches into the
  # cluster.
  endpoint_public_access  = true
  endpoint_private_access = false

  # Access entries replace the aws-auth ConfigMap, and the identity that applies
  # this configuration keeps cluster-admin so that a later session can read
  # Pagerless state.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  addons = {
    # Pinned to the newest build compatible with Kubernetes 1.37, read from
    # `aws eks describe-addon-versions --kubernetes-version 1.37` on 2026-11-17.
    # The VPC CNI must exist before nodes register, because node bootstrap waits
    # for pod networking.
    vpc-cni = {
      version        = "v1.23.3-eksbuild.1"
      before_compute = true
    }
    coredns = {
      version = "v1.14.7-eksbuild.35"
    }
    kube-proxy = {
      version = "v1.37.0-eksbuild.39"
    }
    eks-pod-identity-agent = {
      version = "v1.4.1-eksbuild.3"
    }
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      # With authentication_mode = "API", Amazon EKS creates the EC2_LINUX access
      # entry for a managed node group's IAM role inside CreateNodegroup; Karpenter
      # nodes get their own access entry from module.karpenter.

      # Outbound Systems Manager Session Manager gives interactive shell access to
      # the node without an SSH key or an inbound port-22 rule on the node security
      # group.
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Karpenter and Argo CD run here. The node stays small because everything
      # that can move to a Karpenter node does.
      labels = {
        "pagerless.dev/node-group" = "system"
      }
    }
  }

  # The cluster envelope-encrypts Kubernetes Secrets with a customer-managed KMS
  # key. A key bills USD 1 per month while it exists, so the deletion window is
  # set to the 7-day minimum and the charge stops within a week of teardown.
  kms_key_deletion_window_in_days = 7

  # Karpenter discovers the node security group by this tag. Amazon EKS attaches
  # the same group to the system node group, so the two kinds of node accept the
  # same traffic.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = {
    Name = var.cluster_name
  }
}
