# ADR-0001: Run a private Sigstore instead of public-good Sigstore

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Images for regulated workloads must be signed and verified with identities and trust roots the bank controls. Public-good Fulcio/Rekor publish every signing identity (workflow names, e-mail addresses) to a public log, depend on internet reachability at signing time, and their root of trust is the Sigstore community TUF root, not the corporate PKI.

## Decision

Operate Fulcio, Rekor, the CT log, Trillian and a Timestamp Authority in a dedicated AWS account, with the issuing CA chained to the corporate offline root and trust distributed through a private TUF repository. Public-good Sigstore is not used for internal artifacts (D5).

## Consequences

- Identity data stays inside the bank; audit and data-residency requirements are met in-Region (UAE).
- The platform team now operates stateful services (Trillian, Aurora) and a key ceremony; see 08-operations-dr.md.
- Verification of open-source images signed on public-good Sigstore still uses the public trust root, through the import workflow (05 §3, third-party policy).

## Alternatives considered

- Public-good Sigstore: rejected for the reasons above.
- Key-based cosign signing (long-lived keys in KMS per team): simpler, but loses identity binding and transparency; key sprawl across hundreds of repositories.
- Notary v2 / Notation with the corporate PKI: viable, but no transparency log and weaker Kubernetes ecosystem support for keyless identities.
