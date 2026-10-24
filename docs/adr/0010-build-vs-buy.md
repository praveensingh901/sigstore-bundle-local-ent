# ADR-0010: Build the platform rather than buy

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Red Hat Trusted Artifact Signer (RHTAS) packages the same Sigstore components for OpenShift. Decision D4.

## Decision

Build on upstream charts on EKS with Terraform and Argo CD, because the platform runs on AWS with KMS-backed keys and the bank's GitOps tooling; keep the design close enough to RHTAS that switching remains possible.

## Consequences

- Full control of versions, keys and Region placement; no OpenShift dependency for the signing side.
- The platform team owns upgrades and CVE response for five upstream projects.

## Alternatives considered

- RHTAS on OpenShift: vendor support and an operator, but ties the signing platform to OpenShift and its key-management options; revisit if support SLAs become mandatory.
