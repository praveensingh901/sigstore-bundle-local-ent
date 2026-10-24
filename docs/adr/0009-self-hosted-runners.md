# ADR-0009: Sign on self-hosted runners in AWS

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

The Sigstore endpoints are private. GitHub-hosted runners reach them only with Azure private networking for hosted runners, which would add an Azure network dependency to every signature.

## Decision

Run signing jobs on Actions Runner Controller (ARC 0.15.1) scale sets in the CI account, in a runner group restricted to the platform-workflows reusable workflows, with a hardened image that carries cosign and the TUF root.

## Consequences

- Signing traffic stays on the private network next to Fulcio and Rekor.
- The runner image and ARC become supply-chain components we patch and sign monthly.

## Alternatives considered

- GitHub-hosted runners with Azure private networking: possible; not chosen.
- Exposing Fulcio/Rekor publicly with mTLS: increases attack surface; rejected.
