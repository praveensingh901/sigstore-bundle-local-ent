variable "common_name" {
  type    = string
  default = "Example Bank Sigstore TLS Issuing CA"
}

variable "organization" {
  type    = string
  default = "Example Bank"
}

variable "country" {
  type    = string
  default = "AE"
}

variable "enable_crl" {
  description = "Publish a CRL to S3 (only if something serves crl_cname to clients)."
  type        = bool
  default     = false
}

variable "crl_bucket_name" {
  description = "S3 bucket for the CRL (globally unique); used only when enable_crl = true."
  type        = string
  default     = ""
}

variable "crl_cname" {
  description = "Internal DNS name the CRL is served under (CDP in issued certificates)."
  type        = string
  default     = "crl.sigstore.corp.example"
}

variable "share_with_principals" {
  description = "Account IDs or OU/organization ARNs to share the CA with through AWS RAM."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
