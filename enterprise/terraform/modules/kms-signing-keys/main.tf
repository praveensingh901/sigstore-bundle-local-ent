# Asymmetric signing keys for Fulcio (CA), Rekor, TSA and the TUF online role.
# Multi-Region primary keys with a replica in the DR Region: replicas share key
# material, so certificates and checkpoints stay valid after a Regional failover.
#
# Key policy model (per key):
#   * account root: only so IAM policies can be evaluated; administrative
#     actions are limited to var.key_admin_role_arns (break-glass), which
#     cannot use the key.
#   * signer roles: kms:Sign / kms:GetPublicKey / kms:DescribeKey only.
#   * ceremony role: GetPublicKey always; Sign only on keys that need a CSR,
#     and only inside the ceremony window (var.ceremony_window). Outside the
#     window there is no standing Sign grant, so the role cannot mint
#     certificates or timestamps outside Fulcio and the TSA.
#   * nobody can ScheduleKeyDeletion (explicit Deny for all principals; to
#     delete, a key administrator must first replace the policy, which alarms).

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0, < 7.0"
      configuration_aliases = [aws.dr]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_111:KMS key policy; Resource "*" means this key and principals are explicit.
  #checkov:skip=CKV_AWS_356:KMS key policy; Resource "*" means this key.
  #checkov:skip=CKV_AWS_109:KMS key policy; administration limited to named principals.
  for_each = var.keys

  statement {
    sid       = "EnableIAMPolicyEvaluation"
    actions   = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags", "kms:GetPublicKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  statement {
    sid = "KeyAdministrationBreakGlassOnly"
    actions = [
      "kms:PutKeyPolicy", "kms:EnableKey", "kms:DisableKey", "kms:TagResource", "kms:UntagResource",
      "kms:UpdateAlias", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateKeyDescription",
      "kms:ReplicateKey", "kms:UpdatePrimaryRegion", "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.key_admin_role_arns
    }
  }

  statement {
    sid       = "SignOnly"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = each.value.signer_role_arns
    }
  }

  statement {
    sid       = "CeremonyReadPublicKey"
    actions   = ["kms:GetPublicKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.ceremony_role_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.ceremony_can_sign && var.ceremony_window != null ? [var.ceremony_window] : []
    content {
      sid       = "CeremonySignsCSRInWindow"
      actions   = ["kms:Sign"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [var.ceremony_role_arn]
      }
      condition {
        test     = "DateGreaterThan"
        variable = "aws:CurrentTime"
        values   = [statement.value.start]
      }
      condition {
        test     = "DateLessThan"
        variable = "aws:CurrentTime"
        values   = [statement.value.end]
      }
    }
  }

  statement {
    sid       = "NobodyDeletesSigningKeys"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = var.keys

  description              = each.value.description
  customer_master_key_spec = each.value.key_spec
  key_usage                = "SIGN_VERIFY"
  multi_region             = true
  deletion_window_in_days  = 30
  # Asymmetric keys cannot use automatic rotation; rotation is a ceremony.
  policy = data.aws_iam_policy_document.key[each.key].json
  tags   = merge(var.tags, { "sigstore:role" = each.key })
}

resource "aws_kms_alias" "this" {
  for_each      = var.keys
  name          = "alias/sigstore/${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_kms_replica_key" "dr" {
  for_each = var.create_dr_replicas ? var.keys : {}
  provider = aws.dr

  description             = "${each.value.description} (DR replica)"
  primary_key_arn         = aws_kms_key.this[each.key].arn
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key[each.key].json
  tags                    = merge(var.tags, { "sigstore:role" = each.key, "sigstore:replica" = "true" })
}

resource "aws_kms_alias" "dr" {
  for_each      = var.create_dr_replicas ? var.keys : {}
  provider      = aws.dr
  name          = "alias/sigstore/${each.key}"
  target_key_id = aws_kms_replica_key.dr[each.key].key_id
}
