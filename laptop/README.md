# sigstore-offline — a private, air-gapped Sigstore on your laptop

Keyless container signing with **your own** Fulcio CA, CT log, Rekor
transparency log, Keycloak identity provider, TUF trust mirror, OCI registry
and Kyverno admission control — all running in a local **kind** cluster with
**no internet access**.

```
            laptop (Linux / Windows+WSL2)                         kind cluster "sigstore"
 ┌─────────────────────────────────────────┐        ┌────────────────────────────────────────────────┐
 │ cosign v3 ──https──┐                    │        │ Traefik (TLS *.sigstore.local, 10.96.100.100)  │
 │ browser ───────────┼─► 127.0.0.1:443 ───┼───────►│   ├─ keycloak.sigstore.local  Keycloak (OIDC)  │
 │ docker / crane ────┘                    │        │   ├─ fulcio.sigstore.local    Fulcio ─► CT log │
 │                                         │        │   ├─ rekor.sigstore.local     Rekor ─► Trillian│
 │ sigstore-mirror (registry:2, :5000) ◄───┼────────┤   ├─ registry.sigstore.local  registry:2       │
 │   every platform image, digest-pinned   │ pulls  │   └─ tuf.sigstore.local       TUF mirror       │
 └─────────────────────────────────────────┘        │ Kyverno: only signed images from the registry  │
                                                    └────────────────────────────────────────────────┘
```

## Quick start

```bash
# 1) ONLINE machine — once
scripts/01-build-offline-bundle.sh            # tools + charts + all images -> bundle/

# 2) OFFLINE laptop (Linux or WSL2 shell)
scripts/03-generate-pki.sh
sudo scripts/setup-hosts.sh --trust-ca        # Windows: windows\Setup-Hosts.ps1 (admin), then wsl --shutdown
scripts/install-all.sh                        # cluster + everything + demo signature + policy
scripts/verify-stack.sh                       # all PASS
```

Then: [docs/00-getting-started.md](docs/00-getting-started.md).

## Documentation

| # | Document |
|---|---|
| 00 | [Getting Started](docs/00-getting-started.md) |
| 01 | [Architecture Overview](docs/01-architecture-overview.md) — components, diagrams, how keyless works, private PKI |
| 02 | [Installation Guide](docs/02-installation-guide.md) — every step, command, config and verification |
| 03 | [Keyless Signing Workflow](docs/03-keyless-signing-workflow.md) — build, push, sign, verify, inspect Rekor |
| 04 | [Enterprise Rollout](docs/04-enterprise-rollout.md) — production, Entra ID/Okta/Keycloak, trust distribution, Kyverno/Gatekeeper, CI/CD |
| 05 | [Operations & Maintenance](docs/05-operations-maintenance.md) |
| 06 | [Disaster Recovery](docs/06-disaster-recovery.md) |
| 07 | [Security Hardening](docs/07-security-hardening.md) |
| 08 | [Troubleshooting](docs/08-troubleshooting.md) |
| 09 | [FAQ](docs/09-faq.md) |
| 10 | [Configuration Reference](docs/10-configuration-reference.md) |
| 11 | [Test Report](docs/11-test-report.md) — what was executed and what was not |
| 12 | [Tools & Components Reference](docs/12-tools-reference.md) — what every tool is and why it's used ([Word](docs/Sigstore-Offline-Tools-Reference.docx) · [PowerPoint](docs/Sigstore-Offline-Tools-Overview.pptx)) |
| 13 | [Signing git commits with gitsign](docs/13-gitsign.md) — keyless commit and tag signing against the same private stack |

## Versions (pinned in `config/env.sh`)

| Component | Version |
|---|---|
| kind / node | v0.33.0 / Kubernetes v1.37.0 |
| Fulcio | v1.9.0 (chart 2.11.4) |
| Rekor | v1.5.4 (chart 1.8.7) |
| CT log | scaffolding ct_server v0.7.33 (chart 0.2.69) |
| Trillian | v1.8.0 (chart 0.4.0) |
| cosign | v3.1.3 |
| Keycloak | 26.8.1 |
| Traefik | v3.7.14 (chart 42.0.0) |
| Kyverno | v1.19.1 (chart 3.9.1) |
| registry | 2.8.3 |
| TUF builder/server | scaffolding v0.7.39 |

## Layout

```
config/    env.sh, PKI profiles, Helm values, manifests (templates), policies
scripts/   00–13 install steps, verify-stack, backup/restore, helpers
windows/   PowerShell helpers (hosts + CA trust, native cosign.exe)
ci/        GitHub Actions, GitLab CI, Azure Pipelines examples
examples/  demo app
test/      Docker-only end-to-end test (test/compose/run.sh)
docs/      the documentation set
bundle/ pki/ out/ .generated/   generated — never commit (see .gitignore)
```

## Security note

`pki/` holds every private key and `pki/secrets.env` every password. Back it up
encrypted (`scripts/backup.sh`) and move `pki/fulcio/root.key` to offline
storage after installation — see [docs/07](docs/07-security-hardening.md).
