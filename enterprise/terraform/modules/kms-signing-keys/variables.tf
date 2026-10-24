variable "keys" {
  description = "Signing keys to create, keyed by short name (becomes alias/sigstore/<name>)."
  type = map(object({
    description       = string
    key_spec          = string # ECC_NIST_P256 | ECC_NIST_P384
    signer_role_arns  = list(string)
    ceremony_can_sign = bool
  }))

  validation {
    condition     = alltrue([for k in values(var.keys) : contains(["ECC_NIST_P256", "ECC_NIST_P384"], k.key_spec)])
    error_message = "key_spec must be ECC_NIST_P256 or ECC_NIST_P384 (what Fulcio, Rekor, TSA and TUF support with ECDSA)."
  }
}

variable "key_admin_role_arns" {
  description = "Break-glass roles allowed to administer the keys (they cannot sign). Must include the role Terraform runs as, or CreateKey fails the KMS policy lockout safety check."
  type        = list(string)
}

variable "ceremony_role_arn" {
  description = "Full ARN (including any aws-reserved/sso path) of the role ceremony operators use."
  type        = string
}

variable "ceremony_window" {
  description = <<-EOT
    RFC 3339 start/end of the key ceremony. Set it in the ceremony PR, apply,
    run the ceremony, then set it back to null and apply again (runbook step).
    MFA is enforced by IAM Identity Center for the ceremony permission set;
    aws:MultiFactorAuthPresent is not set on SSO sessions, so it is not used here.
  EOT
  type = object({
    start = string
    end   = string
  })
  default = null
}

variable "create_dr_replicas" {
  description = "Create replica keys in the DR Region (provider aws.dr)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
