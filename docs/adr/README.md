# Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-private-sigstore.md) | Run a private Sigstore instead of public-good Sigstore | Accepted |
| [0002](0002-rekor-v1-now-v2-later.md) | Rekor v1 on Trillian now, Rekor v2 (tiles) later | Accepted |
| [0003](0003-fulcio-ca-key-in-aws-kms.md) | Keep the Fulcio CA key in AWS KMS (not CloudHSM) | Accepted |
| [0004](0004-sigstore-ca-under-offline-root.md) | Chain the Sigstore CA directly to the offline corporate root | Accepted |
| [0005](0005-keycloak-as-oidc-broker.md) | Use Keycloak as the OIDC broker for people | Accepted |
| [0006](0006-ghec-enterprise-unique-issuer.md) | Use the GitHub Enterprise Cloud enterprise-unique OIDC issuer | Accepted |
| [0007](0007-kyverno-on-all-platforms.md) | Enforce with Kyverno on every platform | Accepted |
| [0008](0008-tuf-trust-distribution.md) | Distribute trust with a private TUF repository | Accepted |
| [0009](0009-self-hosted-runners.md) | Sign on self-hosted runners in AWS | Accepted |
| [0010](0010-build-vs-buy.md) | Build the platform rather than buy | Accepted |
| [0011](0011-irsa-for-kms.md) | Use IRSA for Sigstore pods to reach KMS | Accepted |
| [0012](0012-tls-private-ca-cert-manager.md) | Serve TLS from AWS Private CA with cert-manager | Accepted |

Format: context, decision, consequences, alternatives. Supersede an ADR with a new one; never edit a decision after acceptance.
