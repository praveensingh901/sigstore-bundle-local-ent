# ADR-0012: Serve TLS from AWS Private CA with cert-manager

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Every endpoint needs TLS that corporate clients trust, without public certificates and without hand-issued certificates that expire unnoticed.

## Decision

A name-constrained AWS Private CA subordinate (permitted DNS .sigstore.corp.example), signed by the offline root, issues the ALB certificate through ACM and pod certificates through cert-manager's AWS PCA issuer. One subordinate per Region. CRL publication is off; certificates are short-lived.

## Consequences

- Managed renewal (ACM) and automatic rotation (cert-manager, 90 days).
- The name constraint limits the blast radius of the subordinate; cluster-internal names cannot be issued from it.
- PCA cost per CA per Region.

## Alternatives considered

- Certificates from an AD CS issuing CA: manual renewal; rejected.
- cert-manager self-signed CA: not anchored in corporate trust.
