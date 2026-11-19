# The agent's model credentials: an IAM role for the pagerless-agent service
# account, reached through EKS Pod Identity, with no key stored anywhere
# (spec #33, ADR-0023).
#
# The role can call only the Nova 2 Lite inference profile. A cross-Region
# profile is authorized twice: once on the profile in this account, and once on
# the foundation model in each Region the profile may route to. The
# foundation-model resources are listed explicitly rather than wildcarded, so
# the role cannot invoke any other model.

data "aws_iam_policy_document" "agent_bedrock_trust" {
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

data "aws_iam_policy_document" "agent_bedrock" {
  statement {
    sid       = "ConverseOnNova2Lite"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:Converse"]
    resources = local.nova_2_lite_resources
  }
}

locals {
  nova_2_lite_profile = "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:inference-profile/${var.bedrock_model_id}"

  # The US geo profile routes a request to one of these Regions.
  nova_2_lite_regions = ["us-east-1", "us-east-2", "us-west-2"]

  nova_2_lite_resources = concat(
    [local.nova_2_lite_profile],
    [for region in local.nova_2_lite_regions : "arn:aws:bedrock:${region}::foundation-model/${var.bedrock_foundation_model_id}"],
  )
}

resource "aws_iam_role" "agent_bedrock" {
  name               = "${var.cluster_name}-agent-bedrock"
  description        = "Lets the pagerless-agent Job call Amazon Nova 2 Lite through its inference profile."
  assume_role_policy = data.aws_iam_policy_document.agent_bedrock_trust.json

  tags = {
    Name = "${var.cluster_name}-agent-bedrock"
  }
}

resource "aws_iam_role_policy" "agent_bedrock" {
  name   = "nova-2-lite"
  role   = aws_iam_role.agent_bedrock.id
  policy = data.aws_iam_policy_document.agent_bedrock.json
}

# The association maps the role to the service account the Job already uses, so
# the agent's Go code needs no change and stores no credential.
resource "aws_eks_pod_identity_association" "agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "pagerless"
  service_account = "pagerless-agent"
  role_arn        = aws_iam_role.agent_bedrock.arn

  tags = {
    Name = "${var.cluster_name}-agent-bedrock"
  }
}
