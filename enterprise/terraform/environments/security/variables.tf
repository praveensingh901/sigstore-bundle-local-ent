variable "region" {
  type    = string
  default = "me-central-1"
}

variable "dr_region" {
  type    = string
  default = "me-south-1"
}

variable "terraform_role_arn" {
  description = "Role the pipeline assumes; also a key administrator (KMS lockout safety check)."
  type        = string
}

variable "break_glass_role_arns" {
  type = list(string)
}

variable "ceremony_operator_arns" {
  description = "IAM Identity Center permission-set roles of the named ceremony operators."
  type        = list(string)
}

variable "ceremony_window" {
  description = "Set only for the ceremony (RFC 3339 start/end), then back to null."
  type = object({
    start = string
    end   = string
  })
  default = null
}

variable "fulcio_role_arns" {
  description = "Fulcio IRSA roles (prod and DR platform clusters)."
  type        = list(string)
}

variable "rekor_role_arns" {
  type = list(string)
}

variable "tsa_role_arns" {
  type = list(string)
}

variable "github_oidc_provider_arn" {
  description = "IAM OIDC provider for the enterprise-unique GitHub issuer."
  type        = string
}

variable "github_oidc_host" {
  description = "Issuer host and path without scheme, e.g. token.actions.githubusercontent.com/example-bank."
  type        = string
  default     = "token.actions.githubusercontent.com/example-bank"
}

variable "tuf_publisher_subject" {
  description = "Exact OIDC sub of the TUF publish workflow (protected environment)."
  type        = string
  default     = "repo:example-bank/sigstore-trust:environment:tuf-publish"
}

variable "tuf_bucket_name" {
  type = string
}

variable "crl_bucket_name" {
  type = string
}

variable "pca_share_with" {
  description = "Account IDs or OU ARNs that may use the TLS Private CA."
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
  default = {
    "app"        = "sigstore"
    "owner"      = "security-pki"
    "managed-by" = "terraform"
  }
}
