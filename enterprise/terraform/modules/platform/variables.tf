variable "name" {
  description = "Environment name prefix, e.g. sigstore-prod or sigstore-dr."
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  description = "Three Availability Zones."
  type        = list(string)
}

variable "transit_gateway_id" {
  description = "Landing-zone Transit Gateway; 0.0.0.0/0 goes to the central inspection VPC through it."
  type        = string
}

variable "organization_id" {
  description = "AWS Organization ID (o-xxxx) for VPC endpoint policies."
  type        = string
}

variable "extra_endpoint_client_cidrs" {
  description = "Extra CIDRs allowed to the interface endpoints, e.g. a VPC CNI custom-networking pod CIDR."
  type        = list(string)
  default     = []
}

variable "signing_client_cidrs" {
  description = "Networks allowed to the signing ALB (CI runner VPCs, staff VPN ranges)."
  type        = list(string)
}

variable "trust_client_cidrs" {
  description = "Networks allowed to the TUF ALB (every consumer network)."
  type        = list(string)
}

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "zone_name" {
  type    = string
  default = "sigstore.corp.example"
}

variable "create_private_zone" {
  description = "Create the Route 53 private zone (primary Region only); the DR Region associates its VPC with the existing zone."
  type        = bool
  default     = true
}

variable "existing_zone_id" {
  description = "Zone ID to associate with when create_private_zone = false."
  type        = string
  default     = ""
}

variable "security_account_id" {
  description = "Account that owns the KMS signing keys."
  type        = string
}

variable "pca_arn" {
  description = "AWS Private CA in this Region (shared through RAM) for the ALB certificate and cert-manager. Empty skips both until the CA is active."
  type        = string
  default     = ""
}

variable "aurora_global_cluster_ids" {
  description = "Aurora global cluster identifiers to join, keyed by mysql / postgresql. Empty strings create standalone clusters."
  type        = map(string)
  default     = { mysql = "", postgresql = "" }
}

variable "is_secondary_region" {
  description = "True in the DR Region: Aurora clusters join the global cluster as secondaries (no master credentials)."
  type        = bool
  default     = false
}

variable "aurora_engine_versions" {
  description = "Must exist in both Regions and match the global clusters: aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[].EngineVersion'."
  type        = map(string)
  default = {
    mysql      = "8.0.mysql_aurora.3.10.1"
    postgresql = "17.6"
  }
}

variable "aurora_instance_class" {
  type    = string
  default = "db.r7g.large"
}

variable "tuf_bucket_name" {
  description = "S3 bucket for the TUF repository (created in the primary Region only)."
  type        = string
  default     = ""
}

variable "tuf_publisher_role_arn" {
  description = "Role in the security account allowed to write TUF metadata."
  type        = string
  default     = ""
}

variable "signing_key_ids" {
  description = "Multi-Region key IDs (mrk-...) of the signing keys by service (fulcio, rekor, tsa), from environments/security output key_ids. Empty on the first pass."
  type        = map(string)
  default     = {}
}

variable "tuf_reader_role_arns" {
  description = "Roles in other accounts that may read the TUF bucket (replica jobs)."
  type        = list(string)
  default     = ["arn:aws:iam::111111111111:role/sigstore-tuf-replica-reader"]
}

variable "egress_allow_domains" {
  description = "Only domains the platform may resolve outside AWS (Route 53 Resolver DNS Firewall)."
  type        = list(string)
  default = [
    "token.actions.githubusercontent.com.",
    "login.microsoftonline.com.",
    # graph.microsoft.com is not needed: the Entra IdP in realm "staff" sets
    # disableUserInfo and reads e-mail from the ID token. Add it only if
    # userinfo is turned back on.
  ]
}

variable "corp_domains" {
  description = "Corporate DNS suffixes resolved through on-prem forwarding, e.g. the AD FS host (reached over Direct Connect)."
  type        = list(string)
  default     = ["*.corp.example."]
}

variable "admin_role_arns" {
  description = "IAM roles granted cluster-admin through EKS access entries (platform team break-glass and Argo CD)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
