output "key_arns" {
  description = "Primary key ARNs by name."
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

output "key_ids" {
  description = "Key IDs (mrk-..., identical for the DR replica) by name."
  value       = { for k, v in aws_kms_key.this : k => v.key_id }
}

output "replica_key_arns" {
  description = "DR replica key ARNs by name."
  value       = { for k, v in aws_kms_replica_key.dr : k => v.arn }
}

output "kms_uris" {
  description = "Sigstore KMS URIs (awskms:///<arn>) for Fulcio, Rekor, TSA and the TUF publisher."
  value       = { for k, v in aws_kms_key.this : k => "awskms:///${v.arn}" }
}
