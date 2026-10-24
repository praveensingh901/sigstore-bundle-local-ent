# ADR-0003: Keep the Fulcio CA key in AWS KMS (not CloudHSM)

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

The Sigstore Code-Signing CA key must be non-exportable, auditable per use, and available in two Regions. Decision D1 in 00-overview.md.

## Decision

Use an asymmetric KMS key (ECC_NIST_P384, SIGN_VERIFY) in the security account, multi-Region with a replica in the DR Region; Fulcio uses its kmsca backend through IRSA. The same pattern holds the TSA and Rekor keys and the TUF online key.

## Consequences

- KMS is FIPS 140-3 Level 3 validated (HSM-backed) and every Sign call lands in CloudTrail.
- Multi-Region replicas share key material, so failover needs no trust-root change.
- Key policies separate administration from use; the ceremony role can sign only inside a time window.

## Alternatives considered

- CloudHSM with PKCS#11 (Fulcio pkcs11ca): dedicated tenancy and custom key attributes, but cluster operations, client certificates and per-Region clusters; reconsider if a regulator requires single-tenant HSMs.
- File CA key in Secrets Manager: exportable; rejected.
