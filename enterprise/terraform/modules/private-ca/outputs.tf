output "ca_arn" {
  value = aws_acmpca_certificate_authority.tls.arn
}

output "csr_pem" {
  description = "CSR to take to the offline root ceremony (empty after the CA certificate is imported)."
  value       = aws_acmpca_certificate_authority.tls.certificate_signing_request
}
