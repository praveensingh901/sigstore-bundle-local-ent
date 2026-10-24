# Enterprise Private Sigstore: Overview

**Status:** Design, ready for architecture review · **Scope:** organisation-wide keyless signing and verification · **Primary cloud:** AWS

## 1. What this platform does

Every container image (and, later, any build artifact) that reaches production is signed by the identity that built it, the signature is recorded in an append-only transparency log you operate, and every Kubernetes cluster refuses to run images that are unsigned or signed by the wrong identity.

| Question | Answer in this design |
|---|---|
| Who can sign? | GitHub Enterprise Cloud workflows (machine identity) and staff via corporate login (Entra ID or AD FS, brokered by Keycloak) |
| What anchors trust? | Your existing **offline corporate root CA**. It signs the Sigstore issuing CA, whose key lives in **AWS KMS** and cannot be exported |
| Where does signing run? | One central platform in an AWS shared-services account (EKS + Aurora), private endpoints only |
| Who verifies? | Every cluster: EKS, AKS, OpenShift, on-prem Kubernetes. Verification is offline; it needs only a trust file and registry access |
| How does trust reach clusters? | A TUF repository (signed trust metadata) published to S3 and replicated to Azure and on-prem |
| What enforces it? | Kyverno `ImageValidatingPolicy` on every cluster, OpenShift included (see [ADR-0007](../../docs/adr/0007-kyverno-on-all-platforms.md)) |

## 2. Design principles (how large organisations run this)

1. **Sign centrally, verify everywhere.** Signing needs the central services; verification never does. A WAN outage cannot stop deployments that are already signed.
2. **Corporate PKI anchors trust; keys stay in KMS.** The issuing CA, Rekor, Timestamp Authority and TUF online keys are KMS keys that cannot be exported, and every signing call is in CloudTrail. The one exception is the CT log key: the CT front-end cannot use KMS, so it is an encrypted PEM in Secrets Manager that only the CT log role can decrypt.
3. **Machine identities first.** Production images are signed by pipelines, not people. Policies name the exact repositories and branches allowed per namespace.
4. **Trust distribution has a rotation story from day one.** TUF with offline, k-of-n root keys; key rotations reach clusters without touching them.
5. **Policy as code, Audit before Deny.** Same policy source for every cluster; staged enforcement with a documented break-glass.
6. **Everything as code.** Terraform for AWS, Helm and Argo CD for workloads, images pinned by digest, promoted dev → staging → prod.
7. **Same design as the laptop kit.** Engineers learn on the offline kit (`laptop/`) and the tutorial (`tutorial/`); production changes custody, scale and identity, not the trust model.

## 3. Documents in this set

| # | Document | Audience |
|---|---|---|
| 00 | Overview (this page) | Everyone |
| 01 | [Architecture](01-architecture.md): accounts, network, components, data flows | Architects, platform |
| 02 | [PKI and key ceremony](02-pki-and-ceremony.md): corporate root, KMS keys, CSR signing, TSA, TLS | PKI team, security |
| 03 | [Identity](03-identity.md): GitHub Enterprise Cloud, Keycloak broker, Entra ID, AD FS | IAM, DevOps |
| 04 | [Trust distribution (TUF)](04-trust-distribution.md) | Platform, security |
| 05 | [Consumer clusters](05-consumer-clusters.md): EKS, AKS, OpenShift, on-prem | Cluster owners |
| 06 | [CI with GitHub Enterprise Cloud](06-ci-github.md) | DevOps, app teams |
| 07 | [Security controls and threat model](07-security-controls.md) | Security, audit |
| 08 | [Operations and DR](08-operations-dr.md) | SRE, platform |
| 09 | [Rollout plan](09-rollout-plan.md) | Programme, leadership |
| 10 | [Deployment runbook](10-deployment-runbook.md) | Platform engineers |
| 11 | [Source signing with gitsign](11-gitsign.md) | Engineers, platform team |

Architecture decisions are recorded in [`docs/adr/`](../../docs/adr/). The executive summary (Word) and overview deck (PowerPoint) are in [`enterprise/exec/`](../exec/).

## 4. Naming used throughout

Placeholders are consistent across documents and code. Replace them once in `enterprise/terraform/environments/<env>/terraform.tfvars` and `enterprise/helm/values/<env>/`.

| Placeholder | Meaning | Example |
|---|---|---|
| `example-bank` | GitHub Enterprise slug and GitHub organisation | `example-bank` |
| `corp.example` | Corporate DNS suffix | `corp.example` |
| `sigstore.corp.example` | Private Route 53 zone for the platform | |
| `fulcio.sigstore.corp.example` | Fulcio (certificate authority) | |
| `rekor.sigstore.corp.example` | Rekor (transparency log) | |
| `tsa.sigstore.corp.example` | Timestamp Authority | |
| `ctlog.sigstore.corp.example` | CT log, read-only routes for auditors and monitors | |
| `id.sigstore.corp.example` | Keycloak (staff OIDC) | |
| `tuf.sigstore.corp.example` | TUF repository (AWS copy) | |
| `111111111111` | Security / PKI AWS account | |
| `222222222222` | Sigstore shared-services AWS account (prod) | |
| `333333333333` | Example workload account holding application ECR repositories | |
| `REPLACE…` | Values known only after Terraform or the ceremony (ARNs, endpoints, certificates); `grep -rn REPLACE` must be empty before go-live | |
| `me-central-1` | Primary Region (UAE) | |
| `me-south-1` | DR Region (Bahrain); see decision D3 | |

## 5. Decisions needing your confirmation

| # | Decision | Default in this design | Why it needs you |
|---|---|---|---|
| D1 | Fulcio CA key custody | AWS KMS (`kmsca`) | CloudHSM (`pkcs11ca`) if policy requires FIPS 140-3 Level 3 single-tenant HSMs. See [ADR-0003](../../docs/adr/0003-fulcio-ca-key-in-aws-kms.md) |
| D2 | Enterprise-unique GitHub OIDC issuer | Enabled (`include_enterprise_slug: true`) | One API call by a GitHub enterprise administrator; changes `iss` for every workflow, including any existing AWS OIDC trust policies |
| D3 | DR Region | `me-south-1` (Bahrain) | Data-residency rules for log contents (identities, e-mail addresses). Change one variable if another Region is approved |
| D4 | Build vs buy | Upstream Sigstore | Red Hat Trusted Artifact Signer is the supported alternative if you prefer vendor support. See [ADR-0010](../../docs/adr/0010-build-vs-buy.md) |
| D5 | Public-good transparency | Not used | Your Rekor is private. Signatures are not visible on the public `rekor.sigstore.dev`, which is usually what a bank wants |

## 6. What is verified, and what is not

Facts this design depends on were checked against source code or vendor documentation in October 2026 (each check is cited where it is used). The Terraform, Helm values and policies were validated statically (`terraform validate`, `tflint`, `checkov`, `helm template`, `kubeconform`, Kyverno CLI). **Nothing here has been applied to a real AWS account.** [10-deployment-runbook.md](10-deployment-runbook.md) includes a sandbox smoke test to run before the first environment.
