variable "region" {
  type    = string
  default = "me-central-1"
}

variable "terraform_role_arn" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["me-central-1a", "me-central-1b", "me-central-1c"]
}

variable "transit_gateway_id" {
  type = string
}

variable "organization_id" {
  type = string
}

variable "signing_client_cidrs" {
  description = "CI runner VPCs and staff VPN ranges."
  type        = list(string)
}

variable "trust_client_cidrs" {
  description = "All consumer networks (AWS workload VPCs, Azure, on-prem)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "security_account_id" {
  type    = string
  default = "111111111111"
}

variable "pca_arn" {
  description = "Shared TLS Private CA (environments/security output pca_arn). Empty on the first apply, before the CA is active."
  type        = string
  default     = ""
}

variable "tuf_bucket_name" {
  type    = string
  default = "example-bank-sigstore-tuf"
}

variable "tuf_publisher_role_arn" {
  type    = string
  default = "arn:aws:iam::111111111111:role/sigstore-tuf-publisher"
}

variable "signing_key_ids" {
  description = "environments/security output key_ids (second pass)."
  type        = map(string)
  default     = {}
}

variable "admin_role_arns" {
  type    = list(string)
  default = []
}

variable "tags" {
  type = map(string)
  default = {
    "app"        = "sigstore"
    "owner"      = "cloud-platform"
    "env"        = "prod"
    "managed-by" = "terraform"
  }
}
