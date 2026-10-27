# CLAUDE.md — Private Sigstore project

Context for Claude (and people) working in this repository: what the project is,
what we are trying to achieve, where it stands, and what is left.
Last updated: 2026-10-27.

## 1. Goal

Build a **private Sigstore** (keyless signing of container images and git
commits, with our own CA, transparency logs and trust distribution) in two forms:

1. **Laptop kit (`laptop/`)** — a fully offline Sigstore stack on a local kind
   cluster (Windows/WSL2 or Linux). No internet after the bundle is built; all
   images pre-pulled, all certificates generated locally, OIDC via a local
   Keycloak. Used to learn, demo and test.
2. **Enterprise platform (`enterprise/`)** — the same design for a bank on AWS:
   production Sigstore in a hub account, CA keys in KMS under the company's
   offline root + AD CS, identity from Entra ID (brokered by Keycloak) and
   GitHub Enterprise Cloud OIDC, enforcement with Kyverno on EKS, AKS, OpenShift
   and on-prem clusters, TUF for trust distribution, DR in a second Region.

Plus a self-paced course (`tutorial/`, "Sigstore Academy") and executive
material (`enterprise/exec/`).

Original brief (project instructions): architecture docs with diagrams, a
step-by-step offline installation guide, a keyless signing workflow, an
enterprise rollout plan (corporate identity, root CA distribution, Kyverno /
Gatekeeper enforcement, CI/CD examples), and a full documentation set
(Getting Started, Architecture, Installation, Operations, DR, Security
Hardening, Troubleshooting, FAQ) — all copy-paste ready.

## 2. Repository map

| Path | What |
|---|---|
| `laptop/scripts/00-14-*.sh` | Install steps, run in order (`install-all.sh` runs them all). 01 runs on an online machine; everything after is offline. `99-teardown.sh`, `verify-stack.sh`, `backup.sh`/`restore.sh`, `export-trust.sh` (trusted_root.json → files gitsign reads), `dashboard.sh` |
| `laptop/config/env.sh` | Every setting (domain, versions, users, URLs). Single source of truth for the kit |
| `laptop/dashboard/` | Local control panel: `server.py` (Python stdlib only), `index.html`, `test_server.py` (38 tests). Binds 127.0.0.1, token-protected |
| `laptop/test/compose/run.sh` | End-to-end **offline** harness in Docker (no kind): real Fulcio, Rekor, CT log, Trillian, Keycloak, TUF, registry; cosign, Kyverno CLI and gitsign tests in an `--internal` network. `last-run.log` = last passing run |
| `laptop/docs/00-14` | Laptop documentation set (13 = gitsign, 14 = dashboard, 11 = test report) |
| `enterprise/terraform/` | Modules `kms-signing-keys`, `private-ca`, `platform`; environments `security`, `platform-prod`, `platform-dr` |
| `enterprise/helm/` | Values for Fulcio, Rekor, Trillian, CT log, TSA, Kyverno, cert-manager, ESO, LBC; manifests (Keycloak realms, TUF server, rekor-monitor, network policies); prod/dr overlays |
| `enterprise/policies/` | Kyverno ImageValidatingPolicies (+ tests), OpenShift ClusterImagePolicy |
| `enterprise/ci/` | Reusable GitHub workflows: `sign-reusable.yml`, `promote.yml`, `import-third-party.yml`, `tuf-publish.yml`, `tuf-replicate.yml`, `verify-commits.yml` (gitsign PR check). Reference files — they do not run in this repo |
| `enterprise/tuf/` | `tufctl.py` (custodian TUF tooling) + `test.sh` |
| `enterprise/pki-ceremony/` | KMS CSR and certificate verification tools + `test.sh` |
| `enterprise/gitops/`, `consumers/` | Argo CD apps; per-platform consumer overlays |
| `enterprise/docs/00-11` | Enterprise design (10 = deployment runbook, 11 = gitsign) |
| `docs/adr/` | ADR-0001…0012 |
| `tutorial/` | `src/` → `build.py` → `index.html` (single file). 9 modules incl. gitsign lab. Published as the "Sigstore Academy" claude.ai artifact |
| `.github/workflows/validate.yml` | CI: lint (gitleaks, actionlint, shellcheck), enterprise (`tools/validate.sh`: terraform/tflint/checkov, helm+kubeconform, Kyverno tests), tuf, ceremony-tools, tutorial |

## 3. Key decisions (details in ADRs and `enterprise/docs/00-overview.md`)

- Upstream Sigstore, private (no public-good Rekor). Rekor v1 now, v2 later.
- Fulcio CA and TSA keys in AWS KMS (P-384, Multi-Region), issuing CA signed
  by the company's offline root via AD CS in a time-boxed ceremony.
- Keycloak brokers Entra ID / AD FS for people (realm `staff`, e-mail taken
  from `upn`); GitHub Actions OIDC (enterprise-unique issuer) for pipelines.
- Images are signed only by the central `sign.yml` reusable workflow; Kyverno
  checks one identity per attestor (cosign v3 bundles accept one identity).
- Trust is distributed with TUF (S3 + replicas); clusters verify offline.
- gitsign for commits; enforced by an org-ruleset-required `verify-commits`
  workflow (GitHub shows private-CA signatures as "Unverified" — expected; do
  not enable "Require signed commits").
- Regions: me-central-1 primary, me-south-1 DR. No internet egress; VPC
  endpoints + DNS firewall.

## 4. Where we are (status)

Done:
- Laptop kit, docs 00–14, Windows helpers.
- Offline harness passing end to end (cosign sign/verify human + CI identity,
  Rekor inspection, TUF bootstrap, blob + attestation, Kyverno admit/deny and
  attestor shapes, gitsign commit/tag incl. negative tests).
- Enterprise Terraform/Helm/policies/workflows/docs/ADRs; static validation
  green (terraform validate, tflint, checkov 0 failed, kubeconform 647 valid,
  Kyverno tests 5/5).
- Independent validator review: five rounds, last round clean.
- Tutorial (9 modules) and executive docx/pptx.
- Dashboard: built and unit-tested (Python 3.10 and 3.13), live-tested against
  the offline harness (endpoints, certificates, trust, gitsign checks PASS).
- Repo on GitHub, CI green on `main`.

Not yet done / not yet proven:
1. **Full kind install on a real laptop** (`install-all.sh`, steps 04–13) — the
   build sandbox cannot run kind, so cluster-side steps and the dashboard's
   Platform / Pods / Policy checks have never run against a real cluster.
   This is the next thing to do (Windows + Docker Desktop + WSL2, 8 GB RAM).
2. Dashboard UI paths not clicked yet: Configure → Save, Install → Run all,
   the signing smoke test, teardown, widths below 1000 px.
3. **Nothing applied to AWS.** The runbook (`enterprise/docs/10`) starts with
   a sandbox account and an 11-step smoke test; the key ceremony, PCA
   activation and TUF root ceremony are still to be performed.
4. Enterprise prerequisites owned by others: GitHub enterprise-unique OIDC
   issuer (D2), Entra app registration with `upn` optional claim and
   assignment required, AD CS template, data-residency approval for DR Region
   (D3), CloudHSM vs KMS decision (D1), org rulesets for `verify-commits`.
5. Optional: enterprise read-only view in the dashboard (health of EKS/AKS/
   OpenShift policies, KMS/PCA, TUF replica freshness); pin gitsign/cosign
   SHA-256 values in `env.sh`; move CI actions off Node 20
   (`azure/setup-helm`, `hashicorp/setup-terraform`).

## 5. How to work in this repo

Models: **plan and review with Opus; write code with Sonnet** (subagents with
`model: sonnet`). Review Sonnet's output (tests, security-sensitive paths,
screenshots) before pushing.

Before pushing, run what CI runs:
```bash
export PATH=/home/claude/tools/bin:$PATH        # in the Claude sandbox
tools/validate.sh                               # terraform, tflint, checkov, helm, kubeconform, kyverno
bash enterprise/tuf/test.sh && bash enterprise/pki-ceremony/test.sh
actionlint -config-file .github/actionlint.yaml enterprise/ci/*.yml .github/workflows/*.yml
shellcheck -S warning $(git ls-files '*.sh')
(cd laptop/dashboard && python3 -m unittest -q test_server)
python3 tutorial/build.py && node --check tutorial/src/app.js
docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --no-banner
laptop/test/compose/run.sh                      # full offline harness, ~4 min, needs Docker
```

Rules:
- **No secrets in Git.** `.gitignore` blocks keys, tfstate, tfvars, `pki/`,
  `out/`, `bundle/`, harness `.run/`. Test fixtures must not contain literal
  PEM private-key markers (gitleaks); false positives go in `.gitleaksignore`
  with a reason, or `# gitleaks:allow` inline.
- **Check facts against source**, not memory: versions, flags and API shapes
  were verified against upstream source/docs (cite them in docs). Record real
  command output in docs; never invent it.
- Commits by Claude use `Claude <noreply@anthropic.com>` with the
  `Co-Authored-By` and `Claude-Session` trailers. Don't amend or force-push
  pushed history.
- Pinned versions live in `laptop/config/env.sh` (laptop) and the Helm values /
  Terraform (enterprise); update docs and the tutorial when they change.
- After tutorial changes: `python3 tutorial/build.py`, check in a browser, and
  republish the Sigstore Academy artifact.
