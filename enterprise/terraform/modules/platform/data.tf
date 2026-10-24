# Aurora MySQL (Trillian trees + Rekor search index) and Aurora PostgreSQL
# (Keycloak). In the primary Region the clusters are writers of an Aurora
# Global Database; in the DR Region they join as secondaries.

resource "aws_kms_key" "aurora" {
  policy                  = data.aws_iam_policy_document.kms_account.json
  description             = "${var.name} Aurora storage encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  multi_region            = false
  tags                    = var.tags
}

locals {
  aurora = {
    mysql = {
      engine         = "aurora-mysql"
      engine_version = var.aurora_engine_versions["mysql"]
      port           = 3306
      database_name  = "trillian"
      family         = "aurora-mysql8.0"
    }
    postgresql = {
      engine         = "aurora-postgresql"
      engine_version = var.aurora_engine_versions["postgresql"]
      port           = 5432
      database_name  = "keycloak"
      family         = "aurora-postgresql17"
    }
  }
}

# Aurora Global Database does not support RDS-managed master passwords
# (AuroraUserGuide, rds-secrets-manager, Limitations). The primary generates a
# password with an ephemeral resource and writes it, write-only, to its own
# secret and to the cluster: it never appears in plan or state.
ephemeral "aws_secretsmanager_random_password" "master" {
  for_each            = var.is_secondary_region ? {} : local.aurora
  password_length     = 40
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret" "master" {
  #checkov:skip=CKV2_AWS_57:Rotation of the global cluster master password is a runbook step (08 §3).
  for_each   = var.is_secondary_region ? {} : local.aurora
  name       = "${var.name}/admin/${each.key}-master"
  kms_key_id = aws_kms_key.platform_secrets.arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  for_each  = var.is_secondary_region ? {} : local.aurora
  secret_id = aws_secretsmanager_secret.master[each.key].id
  secret_string_wo = jsonencode({
    username = "admin_${each.key}"
    password = ephemeral.aws_secretsmanager_random_password.master[each.key].random_password
  })
  secret_string_wo_version = 1
}

module "aurora" {
  source   = "terraform-aws-modules/rds-aurora/aws"
  version  = "10.4.1"
  for_each = local.aurora

  name           = "${var.name}-${each.key}"
  engine         = each.value.engine
  engine_version = each.value.engine_version
  port           = each.value.port

  global_cluster_identifier = var.aurora_global_cluster_ids[each.key] != "" ? var.aurora_global_cluster_ids[each.key] : null

  # Primary: write-only master password (see above). Secondary: none.
  database_name               = var.is_secondary_region ? null : each.value.database_name
  master_username             = var.is_secondary_region ? null : "admin_${each.key}"
  manage_master_user_password = false
  master_password_wo          = var.is_secondary_region ? null : ephemeral.aws_secretsmanager_random_password.master[each.key].random_password
  master_password_wo_version  = var.is_secondary_region ? null : 1
  is_primary_cluster          = !var.is_secondary_region

  cluster_instance_class = var.aurora_instance_class
  instances = {
    one = {}
    two = {}
  }

  vpc_id               = module.vpc.vpc_id
  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ingress_rules = {
    eks_nodes = {
      referenced_security_group_id = module.eks.node_security_group_id
      description                  = "From EKS nodes"
    }
  }

  # TLS required for every client connection (Trillian, Rekor, Keycloak).
  cluster_parameter_group = {
    family = each.value.family
    parameters = each.key == "mysql" ? [
      { name = "require_secure_transport", value = "ON" },
      { name = "tls_version", value = "TLSv1.2,TLSv1.3", apply_method = "pending-reboot" },
      ] : [
      { name = "rds.force_ssl", value = "1" },
    ]
  }

  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.aurora.arn
  iam_database_authentication_enabled = true
  deletion_protection                 = true
  backup_retention_period             = 35
  preferred_backup_window             = "22:00-23:00"
  copy_tags_to_snapshot               = true
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${var.name}-${each.key}-final"

  enabled_cloudwatch_logs_exports = each.key == "mysql" ? ["audit", "error", "slowquery"] : ["postgresql"]

  tags = merge(var.tags, { "sigstore:data" = each.key })
}
