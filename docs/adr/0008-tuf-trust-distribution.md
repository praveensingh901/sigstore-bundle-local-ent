# ADR-0008: Distribute trust with a private TUF repository

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Verifiers need trusted_root.json and must accept rotations (new CA, new log key) without manual updates to thousands of clients, while a compromised distribution channel must not inject trust.

## Decision

Publish trusted_root.json and signing_config.v0.2.json as TUF targets. Root and targets are signed 2-of-3 with custodian hardware tokens; snapshot and timestamp are signed every six hours with a KMS online key and expire after seven days. Replicas in S3 (both Regions), Azure Blob and on-prem are untrusted storage.

## Consequences

- Clients pin one root.json once.
- An online-key compromise can at most freeze or replay trust for seven days.
- Custodian ceremonies at least every five months to keep targets fresh.

## Alternatives considered

- Bake trusted_root.json into images and policies: every rotation becomes a fleet-wide redeploy.
- Serve trusted_root.json over HTTPS without TUF: the web server becomes a trust anchor.
