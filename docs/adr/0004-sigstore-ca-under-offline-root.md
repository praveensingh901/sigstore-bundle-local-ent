# ADR-0004: Chain the Sigstore CA directly to the offline corporate root

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

The bank's PKI is an offline root with AD CS issuing CAs, which are normally path-length constrained. A code-signing CA under an AD CS issuing CA would need pathlen relaxation and would mix code-signing trust with the Windows/TLS hierarchy.

## Decision

The offline root signs the Sigstore Code-Signing CA (CA:TRUE, pathlen:0, EKU codeSigning) and the TSA certificate at a ceremony. Verifiers take the chain only from trusted_root.json.

## Consequences

- A compromised AD CS issuing CA cannot mint certificates that bundle verifiers or Kyverno accept (caveat for legacy .sig verification without --trusted-root, 02 §1).
- The root's own EKU (if present) must allow codeSigning and timeStamping; checked by verify-issued-cert.sh.
- Two extra certificates per ceremony; validity five years with rotation through TUF.

## Alternatives considered

- Sigstore CA under an AD CS issuing CA: rejected (path length, mixed trust).
- Self-signed Sigstore root separate from corporate PKI: simpler, but loses the corporate anchor the security team requires.
