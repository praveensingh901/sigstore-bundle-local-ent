# Sigstore VPC. No internet gateway: all egress goes through the landing
# zone's Transit Gateway to the central inspection VPC (L7 allowlist owned by
# the network team). This module adds a DNS-layer allowlist on top
# (Route 53 Resolver DNS Firewall) and keeps AWS API traffic on VPC endpoints.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  database_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 6, 48 + i)]
  intra_subnets    = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 240 + i)] # TGW attachment ENIs

  # No public subnets, no IGW, no NAT.
  enable_nat_gateway = false
  create_igw         = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 365

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id                 = var.transit_gateway_id
  vpc_id                             = module.vpc.vpc_id
  subnet_ids                         = module.vpc.intra_subnets
  dns_support                        = "enable"
  security_group_referencing_support = "enable"
  tags                               = merge(var.tags, { Name = var.name })
}

resource "aws_route" "default_via_tgw" {
  count                  = 3 # one private route table per AZ
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# ---------------------------------------------------------------------------
# VPC endpoints: KMS, STS, Secrets Manager, ECR and S3 never leave the VPC.
# Endpoint policies restrict them to principals and resources in the AWS
# Organization, closing the "any bucket / any key in any account" path.
# ---------------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "Interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  for_each          = toset(concat([var.vpc_cidr], var.extra_endpoint_client_cidrs))
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the VPC (and pod CIDRs when CNI custom networking is used)"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

data "aws_region" "current" {}

locals {
  region              = data.aws_region.current.region
  interface_endpoints = ["kms", "sts", "secretsmanager", "ecr.api", "ecr.dkr", "logs", "elasticloadbalancing", "acm-pca", "eks", "eks-auth", "ec2", "autoscaling"]
}

data "aws_iam_policy_document" "endpoint_org_only" {
  #checkov:skip=CKV_AWS_49:VPC endpoint policy; scope comes from the PrincipalOrgID and ResourceOrgID conditions.
  #checkov:skip=CKV_AWS_356:VPC endpoint policy; scope comes from the org conditions.
  #checkov:skip=CKV_AWS_1:Not an IAM identity policy; endpoint policy constrained to the organization.
  #checkov:skip=CKV_AWS_111:Endpoint policy constrained to the organization.
  #checkov:skip=CKV_AWS_109:Endpoint policy constrained to the organization.
  statement {
    sid       = "OrgPrincipalsToOrgResources"
    actions   = ["*"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organization_id]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceOrgID"
      values   = [var.organization_id]
    }
  }
}

# STS: federated calls (AssumeRoleWithWebIdentity = IRSA, AssumeRoleWithSAML)
# carry no aws:PrincipalOrgID, so an org-only policy alone would deny every
# IRSA credential request. AWS-documented pattern: allow them by the target
# role's organization instead.
data "aws_iam_policy_document" "sts_endpoint" {
  #checkov:skip=CKV_AWS_49:VPC endpoint policy; scope comes from the org conditions.
  #checkov:skip=CKV_AWS_356:VPC endpoint policy; scope comes from the org conditions.
  #checkov:skip=CKV_AWS_1:Not an IAM identity policy; endpoint policy constrained to the organization.
  #checkov:skip=CKV_AWS_111:Endpoint policy constrained to the organization.
  #checkov:skip=CKV_AWS_109:Endpoint policy constrained to the organization.
  source_policy_documents = [data.aws_iam_policy_document.endpoint_org_only.json]
  statement {
    sid       = "FederatedToOrgRoles"
    actions   = ["sts:AssumeRoleWithWebIdentity", "sts:AssumeRoleWithSAML"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceOrgID"
      values   = [var.organization_id]
    }
  }
}

# ECR stores layers in AWS-owned S3 buckets, so the S3 gateway endpoint also
# allows reads from the regional ECR layer bucket.
data "aws_iam_policy_document" "s3_endpoint" {
  source_policy_documents = [data.aws_iam_policy_document.endpoint_org_only.json]
  statement {
    sid       = "ECRLayers"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::prod-${local.region}-starport-layer-bucket/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  # Org-only policy on the endpoints that can move data or keys out.
  policy = (each.value == "sts" ? data.aws_iam_policy_document.sts_endpoint.json :
  contains(["kms", "secretsmanager"], each.value) ? data.aws_iam_policy_document.endpoint_org_only.json : null)
  tags = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  policy            = data.aws_iam_policy_document.s3_endpoint.json
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

# ---------------------------------------------------------------------------
# DNS-layer egress allowlist. Allowed names may CNAME to CDN / traffic-manager
# names that are not on the list (login.microsoftonline.com and
# token.actions.githubusercontent.com both do), so ALLOW rules trust the
# redirection chain instead of inspecting each hop.
# ---------------------------------------------------------------------------
resource "aws_route53_resolver_firewall_domain_list" "allow" {
  name    = "${var.name}-allow"
  domains = var.egress_allow_domains
  tags    = var.tags
}

resource "aws_route53_resolver_firewall_domain_list" "aws_and_corp" {
  name = "${var.name}-aws-and-corp"
  domains = concat([
    "*.${local.region}.amazonaws.com.",
    "${local.region}.amazonaws.com.",
    "*.${var.zone_name}.",
    "*.cluster.local.",
    "*.${local.region}.compute.internal.",
  ], var.corp_domains)
  tags = var.tags
}

resource "aws_route53_resolver_firewall_domain_list" "everything" {
  name    = "${var.name}-everything"
  domains = ["*"]
  tags    = var.tags
}

resource "aws_route53_resolver_firewall_rule_group" "egress" {
  name = "${var.name}-egress"
  tags = var.tags
}

resource "aws_route53_resolver_firewall_rule" "allow" {
  name                               = "allow-listed"
  action                             = "ALLOW"
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.allow.id
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.egress.id
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
  priority                           = 100
}

resource "aws_route53_resolver_firewall_rule" "allow_aws" {
  name                               = "allow-aws-and-corp"
  action                             = "ALLOW"
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.aws_and_corp.id
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.egress.id
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
  priority                           = 200
}

resource "aws_route53_resolver_firewall_rule" "block" {
  name                    = "block-everything-else"
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.everything.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.egress.id
  priority                = 900
}

resource "aws_route53_resolver_firewall_rule_group_association" "egress" {
  name                   = "${var.name}-egress"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.egress.id
  vpc_id                 = module.vpc.vpc_id
  priority               = 101
  mutation_protection    = "ENABLED"
  tags                   = var.tags
}

# ---------------------------------------------------------------------------
# Private hosted zone for *.sigstore.corp.example. Other VPCs (CI, workload)
# are associated outside this module; on-prem and Azure forward to Route 53
# Resolver inbound endpoints owned by the network team.
# ---------------------------------------------------------------------------
resource "aws_route53_zone" "private" {
  count = var.create_private_zone ? 1 : 0
  name  = var.zone_name
  vpc {
    vpc_id = module.vpc.vpc_id
  }
  lifecycle {
    ignore_changes = [vpc]
  }
  tags = var.tags
}

resource "aws_route53_zone_association" "dr" {
  count   = var.create_private_zone ? 0 : 1
  zone_id = var.existing_zone_id
  vpc_id  = module.vpc.vpc_id
}

locals {
  zone_id = var.create_private_zone ? aws_route53_zone.private[0].zone_id : var.existing_zone_id
}

# ---------------------------------------------------------------------------
# Two internal ALBs (created by the AWS Load Balancer Controller from Ingress
# groups) use these security groups:
#   signing  - fulcio, rekor, tsa, ctlog, id  : CI runner and staff CIDRs only
#   trust    - tuf                             : every consumer network
# A security group cannot filter by host name, so separating the ALBs is what
# keeps workload networks away from the signing endpoints.
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb_signing" {
  #checkov:skip=CKV2_AWS_5:Attached by the AWS Load Balancer Controller through the Ingress security-groups annotation.
  name_prefix = "${var.name}-alb-signing-"
  description = "Internal ALB for Fulcio, Rekor, TSA, CT log, Keycloak"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_signing" {
  # The VPC itself is included: Fulcio fetches Keycloak's discovery document
  # through its public name (id.sigstore.corp.example) on this ALB.
  for_each          = toset(concat(var.signing_client_cidrs, [var.vpc_cidr]))
  security_group_id = aws_security_group.alb_signing.id
  description       = "HTTPS from CI runners, staff networks and the Sigstore VPC"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_security_group" "alb_trust" {
  #checkov:skip=CKV2_AWS_5:Attached by the AWS Load Balancer Controller through the Ingress security-groups annotation.
  name_prefix = "${var.name}-alb-trust-"
  description = "Internal ALB for the TUF repository"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_trust" {
  for_each          = toset(var.trust_client_cidrs)
  security_group_id = aws_security_group.alb_trust.id
  description       = "HTTPS from consumer networks (TUF metadata, read-only)"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  for_each          = { signing = aws_security_group.alb_signing.id, trust = aws_security_group.alb_trust.id }
  security_group_id = each.value
  description       = "To targets in the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}
