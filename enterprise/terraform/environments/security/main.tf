# Security / PKI account (111111111111): signing keys, AWS Private CA,
# ceremony and TUF publisher roles.
#
# Apply order (first install):
#   1. environments/platform-prod   -> creates the IRSA roles (their ARNs are inputs here)
#   2. environments/security        -> keys with key policies naming those roles; PCA (pending)
#   3. key ceremony (02-pki-and-ceremony.md §4) and PCA certificate import (§5)
#   4. environments/platform-prod again with pca_arn set -> ACM certificate

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
  }
  backend "s3" {
    # Supplied with -backend-config=backend.hcl (bucket, key, region, use_lockfile = true)
  }
}

provider "aws" {
  region = var.region
  assume_role {
    role_arn = var.terraform_role_arn
  }
  default_tags {
    tags = var.tags
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  assume_role {
    role_arn = var.terraform_role_arn
  }
  default_tags {
    tags = var.tags
  }
}

data "aws_iam_policy_document" "ceremony_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.ceremony_operator_arns
    }
    # Operators arrive from an IAM Identity Center permission set that
    # requires MFA at sign-in; SSO sessions do not carry
    # aws:MultiFactorAuthPresent, so the control is the permission-set
    # assignment (named operators only) plus the ceremony window on the keys.
  }
}

resource "aws_iam_role" "ceremony" {
  name                 = "sigstore-ceremony"
  description          = "Key ceremony operator: read public keys; sign the CA and TSA CSRs inside the ceremony window."
  assume_role_policy   = data.aws_iam_policy_document.ceremony_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ceremony" {
  statement {
    sid       = "CeremonyKMS" # the key policies decide when Sign is actually allowed
    actions   = ["kms:GetPublicKey", "kms:DescribeKey", "kms:Sign"]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/sigstore/*"]
    }
  }
  statement {
    sid       = "ImportPCACertificate"
    actions   = ["acm-pca:GetCertificateAuthorityCsr", "acm-pca:ImportCertificateAuthorityCertificate", "acm-pca:DescribeCertificateAuthority"]
    resources = [module.private_ca.ca_arn, module.private_ca_dr.ca_arn]
  }
}

resource "aws_iam_role_policy" "ceremony" {
  name   = "ceremony"
  role   = aws_iam_role.ceremony.id
  policy = data.aws_iam_policy_document.ceremony.json
}

data "aws_caller_identity" "current" {}

# TUF publisher: GitHub Actions workflow in the security repo (OIDC), signs
# snapshot/timestamp with the online key and writes to the TUF bucket.
data "aws_iam_policy_document" "tuf_publisher_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:sub"
      values   = [var.tuf_publisher_subject]
    }
  }
}

resource "aws_iam_role" "tuf_publisher" {
  name               = "sigstore-tuf-publisher"
  assume_role_policy = data.aws_iam_policy_document.tuf_publisher_trust.json
}

data "aws_iam_policy_document" "tuf_publisher" {
  statement {
    sid       = "SignOnlineRoles"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [module.keys.key_arns["tuf-online"]]
  }
  statement {
    sid       = "WriteTUFBucket"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = flatten([for b in [var.tuf_bucket_name, "${var.tuf_bucket_name}-dr"] : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }
}

resource "aws_iam_role_policy" "tuf_publisher" {
  name   = "tuf-publisher"
  role   = aws_iam_role.tuf_publisher.id
  policy = data.aws_iam_policy_document.tuf_publisher.json
}

# Replica jobs (tuf-replicate.yml) only read the published tree.
data "aws_iam_policy_document" "tuf_replica_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:sub"
      values = [
        "repo:example-bank/sigstore-trust:environment:tuf-replicate-azure",
        "repo:example-bank/sigstore-trust:environment:tuf-replicate-onprem",
      ]
    }
  }
}

resource "aws_iam_role" "tuf_replica_reader" {
  name               = "sigstore-tuf-replica-reader"
  assume_role_policy = data.aws_iam_policy_document.tuf_replica_trust.json
}

data "aws_iam_policy_document" "tuf_replica_reader" {
  statement {
    sid       = "ReadTUFBucket"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tuf_bucket_name}", "arn:aws:s3:::${var.tuf_bucket_name}/*"]
  }
}

resource "aws_iam_role_policy" "tuf_replica_reader" {
  name   = "tuf-replica-reader"
  role   = aws_iam_role.tuf_replica_reader.id
  policy = data.aws_iam_policy_document.tuf_replica_reader.json
}

module "keys" {
  source = "../../modules/kms-signing-keys"
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  key_admin_role_arns = concat([var.terraform_role_arn], var.break_glass_role_arns)
  ceremony_role_arn   = aws_iam_role.ceremony.arn
  ceremony_window     = var.ceremony_window

  keys = {
    fulcio-ca = {
      description       = "Sigstore Code-Signing CA (Fulcio kmsca)"
      key_spec          = "ECC_NIST_P384"
      signer_role_arns  = var.fulcio_role_arns
      ceremony_can_sign = true
    }
    tsa = {
      description       = "Sigstore Timestamp Authority"
      key_spec          = "ECC_NIST_P384"
      signer_role_arns  = var.tsa_role_arns
      ceremony_can_sign = true
    }
    rekor = {
      description       = "Rekor transparency log signer"
      key_spec          = "ECC_NIST_P256"
      signer_role_arns  = var.rekor_role_arns
      ceremony_can_sign = false
    }
    tuf-online = {
      description       = "TUF online role (snapshot, timestamp)"
      key_spec          = "ECC_NIST_P256"
      signer_role_arns  = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/sigstore-tuf-publisher"]
      ceremony_can_sign = false
    }
  }

  tags = var.tags
  # The publisher role must exist before its ARN is used in a key policy.
  depends_on = [aws_iam_role.tuf_publisher]
}

module "private_ca" {
  source                = "../../modules/private-ca"
  crl_bucket_name       = var.crl_bucket_name
  share_with_principals = var.pca_share_with
  tags                  = var.tags
}

# AWS Private CA and ACM are Regional: a second subordinate in the DR Region,
# signed by the offline root at the same ceremony.
module "private_ca_dr" {
  source                = "../../modules/private-ca"
  providers             = { aws = aws.dr }
  common_name           = "Example Bank Sigstore TLS Issuing CA (DR)"
  crl_bucket_name       = "${var.crl_bucket_name}-dr"
  crl_cname             = "crl-dr.sigstore.corp.example"
  share_with_principals = var.pca_share_with
  tags                  = var.tags
}

# CloudTrail alarms on key misuse are in 07-security-controls.md §4; the
# organisation trail and its metric filters are owned by the security team's
# landing-zone code and are not duplicated here.

output "kms_uris" {
  value = module.keys.kms_uris
}

output "key_ids" {
  description = "Pass to the platform environments as signing_key_ids (second pass)."
  value = {
    fulcio = module.keys.key_ids["fulcio-ca"]
    rekor  = module.keys.key_ids["rekor"]
    tsa    = module.keys.key_ids["tsa"]
  }
}

output "replica_key_arns" {
  value = module.keys.replica_key_arns
}

output "pca_arn" {
  value = module.private_ca.ca_arn
}

output "pca_csr" {
  value = module.private_ca.csr_pem
}

output "pca_dr_arn" {
  value = module.private_ca_dr.ca_arn
}

output "pca_dr_csr" {
  value = module.private_ca_dr.csr_pem
}

output "ceremony_role_arn" {
  value = aws_iam_role.ceremony.arn
}

output "tuf_publisher_role_arn" {
  value = aws_iam_role.tuf_publisher.arn
}
