# ADR-0002: Rekor v1 on Trillian now, Rekor v2 (tiles) later

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Sigstore's tile-based logs (Rekor v2 / rekor-tiles, TesseraCT) are the long-term direction. At the pinned chart versions the AWS flavour of rekor-tiles has no documented KMS signer and ctlog-tiles supports only POSIX and GCP storage.

## Decision

Deploy Rekor v1.5.4 and the Trillian-based CT log on Aurora MySQL, with KMS signing for Rekor. Re-evaluate every six months; migrate when the AWS flavours support KMS signing and the clients we rely on (cosign, Kyverno) verify v2 entries by default.

## Consequences

- Mature, documented operation on AWS today.
- A future migration adds a second log to trusted_root.json (with start/end times) rather than replacing the old one; old entries stay verifiable.
- Trillian and Aurora are stateful components we must back up and test (08 §4–5).

## Alternatives considered

- rekor-tiles on S3 + MySQL now: rejected until KMS signing is supported.
- Running both logs from day one: doubles operations without a consumer that needs v2.
