# Sigstore shared-services account, DR Region (warm standby, 08-operations-dr.md §5).
# Same module as prod; Aurora clusters join the global clusters as secondaries,
# the private zone is associated rather than created, and the TUF bucket is
# a second copy that the publish pipeline writes after the primary.

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
  }
  backend "s3" {}
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

module "platform" {
  source = "../../modules/platform"

  name                      = "sigstore-dr"
  vpc_cidr                  = var.vpc_cidr
  transit_gateway_id        = var.transit_gateway_id
  organization_id           = var.organization_id
  signing_client_cidrs      = var.signing_client_cidrs
  trust_client_cidrs        = var.trust_client_cidrs
  azs                       = var.azs
  security_account_id       = var.security_account_id
  pca_arn                   = var.pca_arn
  signing_key_ids           = var.signing_key_ids
  aurora_global_cluster_ids = { mysql = "sigstore-mysql", postgresql = "sigstore-postgresql" }
  is_secondary_region       = true
  create_private_zone       = false
  existing_zone_id          = var.private_zone_id
  tuf_bucket_name           = var.tuf_bucket_name # DR copy, written by the same publisher
  tuf_publisher_role_arn    = var.tuf_publisher_role_arn
  admin_role_arns           = var.admin_role_arns
  tags                      = var.tags
}

output "irsa_role_arns" {
  value = module.platform.irsa_role_arns
}
