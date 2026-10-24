# IRSA roles. KMS permissions are scoped by alias with kms:ResourceAliases,
# so this account does not need the security account's key ARNs and the two
# Terraform environments can be applied independently (platform first, so the
# role ARNs exist when the security account's key policies name them).
#
# The key policy in the security account is the second half of the grant:
# it names exactly these role ARNs (modules/kms-signing-keys).

locals {
  sa = {
    fulcio  = { namespace = "fulcio-system", service_account = "fulcio-server", alias = "alias/sigstore/fulcio-ca" }
    rekor   = { namespace = "rekor-system", service_account = "rekor-server", alias = "alias/sigstore/rekor" }
    tsa     = { namespace = "tsa-system", service_account = "tsa-server", alias = "alias/sigstore/tsa" }
    ctlog   = { namespace = "ctlog-system", service_account = "ctlog-secret-reader", alias = "" } # used only by the ctlog SecretStore
    eso     = { namespace = "external-secrets", service_account = "external-secrets", alias = "" }
    pca     = { namespace = "cert-manager", service_account = "aws-privateca-issuer", alias = "" }
    ebs-csi = { namespace = "kube-system", service_account = "ebs-csi-controller-sa", alias = "" }
    lbc     = { namespace = "kube-system", service_account = "aws-load-balancer-controller", alias = "" }
    tuf     = { namespace = "tuf-system", service_account = "tuf-server", alias = "" }
  }
}

data "aws_iam_policy_document" "kms_sign" {
  for_each = { for k, v in local.sa : k => v if v.alias != "" }

  # Second pass (after environments/security exists): exact multi-Region key
  # ID, valid in both Regions. First pass: alias condition only, which AWS does
  # not document for keys in another account; the smoke test (10 §6) must run
  # after the second pass.
  statement {
    sid       = "SignWithOneKeyInSecurityAccount"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = lookup(var.signing_key_ids, each.key, "") != "" ? ["arn:aws:kms:*:${var.security_account_id}:key/${var.signing_key_ids[each.key]}"] : ["arn:aws:kms:*:${var.security_account_id}:key/*"]
    dynamic "condition" {
      for_each = lookup(var.signing_key_ids, each.key, "") != "" ? [] : [1]
      content {
        test     = "ForAnyValue:StringEquals"
        variable = "kms:ResourceAliases"
        values   = [each.value.alias]
      }
    }
  }
}

data "aws_iam_policy_document" "ctlog" {
  statement {
    sid       = "ReadCTKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ctlog_key.arn]
  }
  statement {
    sid       = "DecryptCTKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.ctlog_secret.arn]
  }
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid     = "ReadPlatformSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    # Only the app/ prefix: the CT log key lives under ctlog/ and is readable
    # by the ctlog-secret-reader role alone.
    resources = ["arn:aws:secretsmanager:*:*:secret:${var.name}/app/*"]
  }
  statement {
    sid       = "DecryptPlatformSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.platform_secrets.arn]
  }
}

data "aws_iam_policy_document" "pca" {
  statement {
    sid       = "IssueFromSharedPCA"
    actions   = ["acm-pca:DescribeCertificateAuthority", "acm-pca:GetCertificate", "acm-pca:IssueCertificate"]
    resources = [var.pca_arn == "" ? "arn:aws:acm-pca:*:*:certificate-authority/none" : var.pca_arn]
  }
}

data "aws_iam_policy_document" "tuf" {
  statement {
    sid       = "ReadTUFRepository"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = var.tuf_bucket_name == "" ? ["arn:aws:s3:::none"] : ["arn:aws:s3:::${var.tuf_bucket_name}", "arn:aws:s3:::${var.tuf_bucket_name}/*"]
  }
}

locals {
  inline_policies = merge(
    { for k, v in data.aws_iam_policy_document.kms_sign : k => v.json },
    {
      ctlog = data.aws_iam_policy_document.ctlog.json
      eso   = data.aws_iam_policy_document.eso.json
      pca   = data.aws_iam_policy_document.pca.json
      tuf   = data.aws_iam_policy_document.tuf.json
    },
  )
}

resource "aws_iam_policy" "irsa" {
  for_each = local.inline_policies
  name     = "${var.name}-${each.key}"
  policy   = each.value
  tags     = var.tags
}

module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version  = "6.8.2"
  for_each = local.sa

  name            = "${var.name}-${each.key}"
  use_name_prefix = false

  attach_ebs_csi_policy                  = each.key == "ebs-csi"
  attach_load_balancer_controller_policy = each.key == "lbc"

  policies = contains(keys(local.inline_policies), each.key) ? { main = aws_iam_policy.irsa[each.key].arn } : {}

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.namespace}:${each.value.service_account}"]
    }
  }

  tags = var.tags
}
