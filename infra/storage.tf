# Storage for the workloads that persist state: Loki, Tempo and the Pagerless
# history claim. Amazon EKS does not install a CSI driver by default, so without
# this the claims would stay Pending and the stack would never become Healthy.
#
# Dynamically provisioned volumes are not part of this state: the StorageClass in
# platform/cloud/storage tags every volume it creates with project=pagerless, so
# the teardown check sees a volume that outlived its claim, and `make cloud-down`
# deletes the claims before it destroys the cluster.

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    sid    = "AllowEksPodIdentity"
    effect = "Allow"

    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  description        = "Lets the EBS CSI driver provision and delete the stack's volumes."
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json

  tags = {
    Name = "${var.cluster_name}-ebs-csi"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# The driver's controller authenticates through Pod Identity, like every other
# in-cluster AWS client here, so no service-account annotation or key exists.
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  tags = {
    Name = "${var.cluster_name}-ebs-csi"
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = "v1.68.0-eksbuild.1"

  # The controller needs its role before its pods start calling EC2.
  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}
