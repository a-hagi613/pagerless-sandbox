# The model gateway's AWS identity.
#
# The showcase's Pagerless install needs an OpenAI-compatible model endpoint, and
# the owner chose Amazon Bedrock with Nova 2 Lite (ADR-0023 in the product
# repository). The v2 agent speaks only the OpenAI protocol and cannot sign a
# SigV4 request, so an in-cluster gateway (platform/model-gateway) translates
# between the two. This file gives that gateway the only AWS identity it needs.
#
# No key is stored anywhere: the role is assumed through EKS Pod Identity, the
# mechanism this stack already uses for the EBS CSI driver and the Karpenter
# controller, from the `model-gateway` ServiceAccount in the `pagerless`
# namespace. Until that association exists the gateway runs without credentials
# and its model calls fail; nothing else in the cluster can assume the role.

data "aws_iam_policy_document" "model_gateway_trust" {
  statement {
    sid    = "AllowEksPodIdentity"
    effect = "Allow"

    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Only this cluster may hand the role to a pod, and only in this account, so
    # a Pod Identity association created elsewhere cannot borrow it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "model_gateway" {
  name               = "${var.cluster_name}-model-gateway"
  description        = "Lets the in-cluster model gateway invoke Amazon Nova 2 Lite on Bedrock."
  assume_role_policy = data.aws_iam_policy_document.model_gateway_trust.json

  tags = {
    Name = "${var.cluster_name}-model-gateway"
  }
}

# Two verbs on one model and one profile. The `us.` geo cross-Region inference
# profile is a resource in the calling region, and it forwards the call to the
# foundation model in whichever Region of the group is closest, so the foundation
# model ARN carries a Region wildcard rather than one Region.
data "aws_iam_policy_document" "model_gateway" {
  statement {
    sid    = "InvokeNova2Lite"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      "arn:aws:bedrock:*::foundation-model/us.amazon.nova-2-lite-v1:0",
      "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:inference-profile/us.amazon.nova-2-lite-v1:0",
    ]
  }

  # ListFoundationModels takes no resource, so it cannot be narrowed further.
  # It is read-only and exists so an operator can confirm the model is available
  # in the Region before blaming the gateway.
  statement {
    sid    = "ListFoundationModels"
    effect = "Allow"

    actions   = ["bedrock:ListFoundationModels"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "model_gateway" {
  name   = "model-gateway-invoke-nova"
  role   = aws_iam_role.model_gateway.id
  policy = data.aws_iam_policy_document.model_gateway.json
}

# The association is the credential: Pod Identity matches this namespace and
# ServiceAccount and injects short-lived credentials into the matching pods.
resource "aws_eks_pod_identity_association" "model_gateway" {
  cluster_name    = module.eks.cluster_name
  namespace       = "pagerless"
  service_account = "model-gateway"
  role_arn        = aws_iam_role.model_gateway.arn

  tags = {
    Name = "${var.cluster_name}-model-gateway"
  }
}
