# Secrets, the CT log key secret, the TUF bucket (primary Region only), and
# the ACM private certificate for the internal ALB.

resource "aws_kms_key" "platform_secrets" {
  description             = "${var.name} Secrets Manager (platform)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_account.json
  tags                    = var.tags
}

data "aws_caller_identity" "current" {}

locals {
  account_root = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  # Role ARNs are built from names (not module outputs) so the key policies do
  # not create a dependency cycle with the IRSA roles that use them.
  ctlog_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-ctlog"
}

# Key policy for platform-internal keys: IAM policies in this account decide
# (account root delegation), which is the AWS default made explicit.
data "aws_iam_policy_document" "kms_account" {
  #checkov:skip=CKV_AWS_111:KMS key policy; Resource "*" means this key and principals are explicit.
  #checkov:skip=CKV_AWS_356:KMS key policy; Resource "*" means this key.
  #checkov:skip=CKV_AWS_109:KMS key policy; administration limited to named principals.
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }
}

# CT log key secret: only the ctlog IRSA role may decrypt; the ceremony
# operator role may encrypt (put-secret-value) and nothing else.
data "aws_iam_policy_document" "ctlog_secret" {
  #checkov:skip=CKV_AWS_111:KMS key policy; Resource "*" means this key and principals are explicit.
  #checkov:skip=CKV_AWS_356:KMS key policy; Resource "*" means this key.
  #checkov:skip=CKV_AWS_109:KMS key policy; administration limited to named principals.
  statement {
    sid = "KeyAdministration"
    actions = [
      "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*",
      "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
      "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:RotateKeyOnDemand",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }
  statement {
    sid       = "DecryptOnlyForCTLog"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalArn"
      values   = [local.ctlog_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "EncryptForCeremony"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "ctlog_secret" {
  description             = "${var.name} CT log private key secret"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ctlog_secret.json
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "ctlog_key" {
  #checkov:skip=CKV2_AWS_57:The CT log key cannot be rotated automatically; rotation is a ceremony plus a trusted-root update (02 §7).
  name        = "${var.name}/ctlog/private-key"
  description = "CT log encrypted PEM private key + password, written once at the key ceremony"
  kms_key_id  = aws_kms_key.ctlog_secret.arn
  tags        = var.tags
  # The value is put by the ceremony operator (aws secretsmanager put-secret-value),
  # never by Terraform, so it is not in state.
}

module "tuf_bucket" {
  count   = var.tuf_bucket_name == "" ? 0 : 1
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket = var.tuf_bucket_name

  versioning = {
    enabled = true
  }

  object_lock_enabled      = true
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
  object_lock_configuration = {
    rule = {
      default_retention = {
        mode = "GOVERNANCE"
        days = 30
      }
    }
  }

  server_side_encryption_configuration = {
    rule = {
      # SSE-S3: the publisher writes from the security account, and objects
      # encrypted with that account's aws/s3 key could not be read here.
      # TUF metadata is signed and not secret; integrity comes from TUF.
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_deny_insecure_transport_policy = true
  attach_policy                         = true
  policy                                = data.aws_iam_policy_document.tuf_bucket.json

  tags = var.tags
}

data "aws_iam_policy_document" "tuf_bucket" {
  statement {
    sid       = "OnlyPublisherWrites"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:BypassGovernanceRetention", "s3:PutObjectRetention"]
    resources = ["arn:aws:s3:::${var.tuf_bucket_name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [var.tuf_publisher_role_arn]
    }
  }

  # Principals are matched with aws:PrincipalArn conditions instead of being
  # named as principals: S3 rejects a policy naming a role that does not exist
  # yet, and the security-account roles are created after this bucket.
  statement {
    sid       = "PublisherWrite"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.tuf_bucket_name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalArn"
      values   = [var.tuf_publisher_role_arn]
    }
  }

  statement {
    sid       = "CrossAccountReaders"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tuf_bucket_name}", "arn:aws:s3:::${var.tuf_bucket_name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalArn"
      values   = concat([var.tuf_publisher_role_arn], var.tuf_reader_role_arns)
    }
  }

  statement {
    sid       = "NobodyBypassesRetention"
    effect    = "Deny"
    actions   = ["s3:BypassGovernanceRetention", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::${var.tuf_bucket_name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_acm_certificate" "alb" {
  #checkov:skip=CKV2_AWS_71:One wildcard for the private zone *.sigstore.corp.example on an internal ALB, issued by a name-constrained private CA.
  count                     = var.pca_arn == "" ? 0 : 1
  domain_name               = "*.${var.zone_name}"
  subject_alternative_names = [var.zone_name]
  certificate_authority_arn = var.pca_arn
  key_algorithm             = "EC_prime256v1"
  tags                      = var.tags
  lifecycle {
    create_before_destroy = true
  }
}
