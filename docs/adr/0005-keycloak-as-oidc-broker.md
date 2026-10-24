# ADR-0005: Use Keycloak as the OIDC broker for people

- **Status:** Accepted (pending sign-off of decisions D1–D5, 00-overview.md §5)
- **Date:** 2026-10-24
- **Deciders:** Head of Cloud, Security / PKI, Cloud Platform, DevOps Platform

## Context

Staff identities live in Microsoft Entra ID and, for restricted zones, AD FS. Fulcio's email issuer type requires email_verified=true, which Entra ID tokens do not reliably carry, and verifiers should see one stable issuer for people.

## Decision

Deploy Keycloak 26.8.1 (operator) with realm staff brokering Entra ID (OIDC) and AD FS (OIDC); identity providers trust e-mail and read claims from the ID token only. Fulcio trusts https://id.sigstore.corp.example/realms/staff.

## Consequences

- One issuer in every policy; changing upstream IdPs never changes a policy.
- Keycloak becomes a tier-1 service with its own database and upgrades.
- MFA stays upstream (Conditional Access / AD FS).

## Alternatives considered

- Entra ID directly with Fulcio skip-email-verification: possible, but two issuers for people and a weaker e-mail assertion.
- Dex: smaller, but weaker AD FS/SAML support and admin tooling.
