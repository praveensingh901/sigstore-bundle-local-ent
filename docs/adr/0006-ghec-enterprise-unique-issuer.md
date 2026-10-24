# ADR-0006: Use the GitHub Enterprise Cloud enterprise-unique OIDC issuer

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

With the default issuer https://token.actions.githubusercontent.com, Fulcio would accept tokens from any GitHub customer; policies would then depend entirely on SAN matching.

## Decision

Enable include_enterprise_slug so workflow tokens carry iss=https://token.actions.githubusercontent.com/example-bank; Fulcio trusts only that issuer (03 §1).

## Consequences

- Only workflows in our enterprise can obtain certificates from our Fulcio.
- Every existing cloud OIDC trust that pins the old issuer must be updated before the switch (inventory in 09 risks).

## Alternatives considered

- Default issuer plus strict SAN patterns: rejected; one mistake in a pattern admits any GitHub user.
