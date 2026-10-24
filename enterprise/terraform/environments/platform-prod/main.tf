# Sigstore shared-services account (222222222222), primary Region.

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

# Aurora Global Databases: the DR environment joins these as secondaries.
locals {
  aurora_engine_versions = {
    mysql      = "8.0.mysql_aurora.3.10.1"
    postgresql = "17.6"
  }
}

resource "aws_rds_global_cluster" "this" {
  for_each = {
    mysql      = { engine = "aurora-mysql", engine_version = local.aurora_engine_versions["mysql"] }
    postgresql = { engine = "aurora-postgresql", engine_version = local.aurora_engine_versions["postgresql"] }
  }
  global_cluster_identifier = "sigstore-${each.key}"
  engine                    = each.value.engine
  engine_version            = each.value.engine_version
  storage_encrypted         = true
  deletion_protection       = true
}

module "platform" {
  source = "../../modules/platform"

  name                      = "sigstore-prod"
  vpc_cidr                  = var.vpc_cidr
  transit_gateway_id        = var.transit_gateway_id
  organization_id           = var.organization_id
  signing_client_cidrs      = var.signing_client_cidrs
  trust_client_cidrs        = var.trust_client_cidrs
  azs                       = var.azs
  security_account_id       = var.security_account_id
  pca_arn                   = var.pca_arn
  signing_key_ids           = var.signing_key_ids
  aurora_global_cluster_ids = { for k, v in aws_rds_global_cluster.this : k => v.id }
  is_secondary_region       = false
  aurora_engine_versions    = local.aurora_engine_versions
  tuf_bucket_name           = var.tuf_bucket_name
  tuf_publisher_role_arn    = var.tuf_publisher_role_arn
  admin_role_arns           = var.admin_role_arns
  tags                      = var.tags
}

output "platform" {
  value = {
    cluster_name              = module.platform.cluster_name
    irsa_role_arns            = module.platform.irsa_role_arns
    aurora                    = module.platform.aurora_endpoints
    alb_cert                  = module.platform.alb_certificate_arn
    zone_id                   = module.platform.private_zone_id
    ctlog_secret              = module.platform.ctlog_secret_arn
    aurora_master_secret_arns = module.platform.aurora_master_secret_arns
  }
}
