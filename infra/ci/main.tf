# GitHub Actions authenticates with a short-lived OIDC token instead of an AWS
# access key (ADR-0009). Two roles keep the two jobs apart: a read-only role for
# the pull request plan, and a teardown role for the nightly destroy.

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Every certificate in the chain, so a rotation of an intermediate does not
  # silently stop the workflows from authenticating.
  thumbprint_list = [for certificate in data.tls_certificate.github.certificates : certificate.sha1_fingerprint]

  tags = {
    Name = "github-actions"
  }
}

locals {
  # Repositories created after 2026-07-15 carry immutable subject claims, which
  # include the owner and repository IDs. Both roles trust that exact form, so a
  # recycled repository name cannot inherit either role.
  subject_prefix = "repo:${split("/", var.github_repository)[0]}@${var.github_repository_owner_id}/${split("/", var.github_repository)[1]}@${var.github_repository_id}"

  state_bucket_arn = "arn:aws:s3:::${var.state_bucket}"

  # Every identity the session stack creates carries this prefix.
  name_prefix = "pagerless-"
}

################################################################################
# Plan: pull requests only, read-only, no state writes
################################################################################

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "PullRequestsFromThisRepository"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid    = "ReadStackState"
    effect = "Allow"

    actions = ["s3:ListBucket", "s3:GetObject"]

    resources = [
      local.state_bucket_arn,
      "${local.state_bucket_arn}/phase-3/*",
    ]
  }

  statement {
    sid    = "ReadEksAmiParametersForAPlan"
    effect = "Allow"

    actions = ["ssm:GetParameter", "ssm:GetParameters"]

    # The EKS node group module resolves its Amazon Linux 2023 AMI from the
    # public EKS parameter namespace; the plan reads it before anything exists.
    resources = ["arn:aws:ssm:${var.aws_region}::parameter/aws/service/eks/optimized-ami/*"]
  }

  statement {
    sid    = "ReadInfrastructureForAPlan"
    effect = "Allow"

    actions = [
      "sts:GetCallerIdentity",
      "autoscaling:Describe*",
      "cloudwatch:Describe*",
      "cloudwatch:ListTagsForResource",
      "ec2:Describe*",
      "eks:Describe*",
      "eks:List*",
      # Karpenter's interruption rules are EventBridge rules, and a plan reads
      # each one it manages. Like the KMS reads below, this only fails while a
      # session is standing.
      "events:DescribeRule",
      "events:ListRules",
      "events:ListTagsForResource",
      "events:ListTargetsByRule",
      "iam:Get*",
      "iam:List*",
      "kms:Describe*",
      # A plan refreshes the cluster's KMS key, and reading the key needs its
      # policy and its rotation status. Without these the plan fails with
      # AccessDenied for exactly as long as a session is standing, which is when
      # the plan matters most.
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:List*",
      "logs:Describe*",
      "logs:ListTags*",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
      "tag:GetResources",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role" "plan" {
  name               = var.plan_role_name
  description        = "Lets a pull request run a read-only terraform plan of infra/."
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json

  tags = {
    Name = var.plan_role_name
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

################################################################################
# Destroy: the default branch only, the permissions a teardown needs
################################################################################

data "aws_iam_policy_document" "destroy_trust" {
  statement {
    sid     = "DefaultBranchOfThisRepository"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:ref:refs/heads/main"]
    }
  }
}

# Destroying the stack deletes the roles and policies the cluster created. Those
# writes are scoped to this project's names, which every resource the stack
# creates uses.
data "aws_iam_policy_document" "destroy_identities" {
  statement {
    sid    = "DeleteThisProjectsIdentities"
    effect = "Allow"

    actions = [
      "iam:DeleteInstanceProfile",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetInstanceProfile",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListPolicyVersions",
      "iam:ListRolePolicies",
      "iam:RemoveRoleFromInstanceProfile",
    ]

    # Karpenter names the instance profiles it creates after the cluster with an
    # underscore, so this pattern carries no separator. It also creates them
    # under /karpenter/<region>/<cluster>/, so the ARN's resource part starts
    # with the path rather than the name and the root pattern cannot match it;
    # that is why the path pattern is listed separately. An orphaned Karpenter
    # role, if one ever survives, sits under the same path.
    resources = [
      "arn:aws:iam::${var.aws_account_id}:instance-profile/${local.name_prefix}*",
      "arn:aws:iam::${var.aws_account_id}:instance-profile/karpenter/*",
      "arn:aws:iam::${var.aws_account_id}:policy/${local.name_prefix}*",
      "arn:aws:iam::${var.aws_account_id}:role/${local.name_prefix}*",
      "arn:aws:iam::${var.aws_account_id}:role/karpenter/*",
    ]
  }
}

# Everything a teardown reads and deletes, and nothing that creates, tags or
# starts anything (spec #33, ticket #36). The managed node group is an EKS
# resource, so deleting it never touches Autoscaling directly, and the volumes
# belong to the CSI driver rather than to this state.
data "aws_iam_policy_document" "destroy" {
  statement {
    sid    = "ReadTheStackDuringDestroy"
    effect = "Allow"

    actions = [
      "ec2:Describe*",
      "eks:Describe*",
      "eks:List*",
      "events:DescribeRule",
      "events:ListRules",
      "events:ListTargetsByRule",
      "iam:Get*",
      "iam:List*",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:ListAliases",
      "kms:ListKeys",
      "kms:ListResourceTags",
      "logs:Describe*",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueues",
      "sqs:ListQueueTags",
      "sts:GetCallerIdentity",
      "tag:GetResources",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "DeleteTheStack"
    effect = "Allow"

    actions = [
      "ec2:DeleteInternetGateway",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:DeleteRouteTable",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet",
      "ec2:DeleteTags",
      "ec2:DeleteVpc",
      "ec2:DetachInternetGateway",
      "ec2:DisassociateRouteTable",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "eks:DeleteAccessEntry",
      "eks:DeleteAddon",
      "eks:DeleteCluster",
      "eks:DeleteFargateProfile",
      "eks:DeleteNodegroup",
      "eks:DeletePodIdentityAssociation",
      "events:DeleteRule",
      "events:RemoveTargets",
      "kms:DeleteAlias",
      "kms:DisableKey",
      "kms:ScheduleKeyDeletion",
      "logs:DeleteLogGroup",
      "logs:DeleteResourcePolicy",
      "sqs:DeleteQueue",
    ]

    resources = ["*"]
  }

  # The volume sweep deletes the EBS volumes the CSI driver created. They are
  # outside this state, so terraform destroy cannot remove them, and the nightly
  # refuses to report zero residue while one still bills. The sweep is the only
  # caller, and it must not widen the rest of this role: DeleteVolume is granted
  # on one action, in one Region, and only for volumes carrying a tag the session
  # itself put there. Two tags identify a session volume and either is enough:
  #
  #   - the driver tags every volume it creates with ebs.csi.aws.com/cluster=true
  #     and documents that tag as the one to bound the driver's own delete
  #     permission to the volumes it manages (docs/tagging.md at v1.68.0, the
  #     add-on version infra/storage.tf pins);
  #   - platform/cloud/storage sets tagSpecification_1=project=pagerless, so
  #     every volume the session's default StorageClass provisions carries the
  #     cost-allocation tag even if the driver's default tags were ever disabled.
  #
  # A volume without either tag is refused, which is the safe direction: the
  # teardown check names it instead of the sweep silently deleting something the
  # session did not create. Nothing has been observed live yet; both tags are
  # read from the pinned driver's source and from this repository's StorageClass.
  statement {
    sid    = "DeleteTheSessionsCsiVolumes"
    effect = "Allow"

    actions   = ["ec2:DeleteVolume"]
    resources = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ebs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DeleteTheSessionsTaggedVolumes"
    effect = "Allow"

    actions   = ["ec2:DeleteVolume"]
    resources = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = ["pagerless"]
    }
  }

  # Karpenter launches capacity with an `instant` EC2 Fleet, which Terraform never
  # records. The fleet sweep deletes the ones that carry the session's tags, and
  # DeleteFleets cannot be conditioned on a tag a fleet may not carry, so it is
  # scoped to this Region and account instead of `*`; the sweep itself refuses
  # untagged fleets and lets the residue check name them.
  statement {
    sid    = "DeleteTheSessionsFleets"
    effect = "Allow"

    actions   = ["ec2:DeleteFleets"]
    resources = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:fleet/*"]
  }

  statement {
    sid    = "ReadAndWriteStackState"
    effect = "Allow"

    actions = ["s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject"]

    resources = [
      local.state_bucket_arn,
      "${local.state_bucket_arn}/phase-3/*",
    ]
  }

  statement {
    sid    = "ReadEksAmiParameters"
    effect = "Allow"

    actions = ["ssm:GetParameter", "ssm:GetParameters"]

    resources = ["arn:aws:ssm:${var.aws_region}::parameter/aws/service/eks/optimized-ami/*"]
  }
}

resource "aws_iam_role" "destroy" {
  name               = var.destroy_role_name
  description        = "Lets the nightly workflow destroy any remaining Pagerless cluster."
  assume_role_policy = data.aws_iam_policy_document.destroy_trust.json

  tags = {
    Name = var.destroy_role_name
  }
}

resource "aws_iam_role_policy" "destroy" {
  name   = "destroy"
  role   = aws_iam_role.destroy.id
  policy = data.aws_iam_policy_document.destroy.json
}

resource "aws_iam_role_policy" "destroy_identities" {
  name   = "pagerless-identities"
  role   = aws_iam_role.destroy.id
  policy = data.aws_iam_policy_document.destroy_identities.json
}
