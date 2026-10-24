# ADR-0007: Enforce with Kyverno on every platform

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Clusters run on EKS, AKS, OpenShift and on-prem Kubernetes. OpenShift's native ClusterImagePolicy matches only e-mail SANs and only reads legacy .sig tags, so it cannot verify GitHub workflow identities or cosign v3 bundles.

## Decision

Kyverno 1.19 ImageValidatingPolicy is the enforcement point everywhere, from one policy pack with per-platform overlays (TUF replica, registry, credentials). The native OpenShift policy is optional defence in depth for e-mail-identity images.

## Consequences

- One policy language and one test suite for all platforms.
- Kyverno is a fail-closed admission webhook: three replicas, PDB, and system-namespace exclusions are mandatory.
- Policies verify offline from the bundle and TUF; no runtime dependency on the Sigstore platform.

## Alternatives considered

- Sigstore policy-controller: narrower scope, fewer platform integrations.
- OPA Gatekeeper with an external data provider: needs a custom verification service.
