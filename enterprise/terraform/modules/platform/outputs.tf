output "vpc_id" {
  value = module.vpc.vpc_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "irsa_role_arns" {
  description = "Annotate the service accounts with these (eks.amazonaws.com/role-arn). fulcio/rekor/tsa go into the security account's key policies."
  value       = { for k, v in module.irsa : k => v.arn }
}

output "aurora_endpoints" {
  value = { for k, v in module.aurora : k => v.cluster_endpoint }
}

output "aurora_master_secret_arns" {
  value = { for k, v in aws_secretsmanager_secret.master : k => v.arn }
}

output "ctlog_secret_arn" {
  value = aws_secretsmanager_secret.ctlog_key.arn
}

output "alb_certificate_arn" {
  value = try(aws_acm_certificate.alb[0].arn, null)
}

output "alb_security_group_ids" {
  description = "Use in the Ingress annotation alb.ingress.kubernetes.io/security-groups for the signing and trust Ingress groups."
  value       = { signing = aws_security_group.alb_signing.id, trust = aws_security_group.alb_trust.id }
}

output "private_zone_id" {
  value = local.zone_id
}

output "tuf_bucket_arn" {
  value = try(module.tuf_bucket[0].s3_bucket_arn, null)
}
