# ADR-0011: Use IRSA for Sigstore pods to reach KMS

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Fulcio, Rekor and the TSA sign with keys in the security account. The upstream charts' aws kmsType expects static access keys in a Kubernetes Secret.

## Decision

Give each service account an IAM role (IRSA) whose policy allows Sign/GetPublicKey/DescribeKey on exactly one key, matched by alias with kms:ResourceAliases; the key policy in the security account names the same role. Charts run with kmsType none so no access keys exist.

## Consequences

- No long-lived AWS credentials anywhere in the platform.
- Two-sided grant: both the role policy and the key policy must allow the call.
- Terraform apply order: platform roles before security key policies.

## Alternatives considered

- Static access keys (chart default): rejected.
- EKS Pod Identity: equivalent; IRSA chosen because the IAM module and the charts' annotations support it directly.
