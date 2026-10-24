# 07 Security Controls and Threat Model

## 1. Assets

| Asset | Why it matters | Where |
|---|---|---|
| Sigstore Code-Signing CA key | Can mint certificates for any identity Fulcio trusts | AWS KMS, security account |
| Rekor key | Can forge log entries and checkpoints | AWS KMS |
| TSA key | Can forge timestamps | AWS KMS |
| CT log key | Can forge SCTs | Secrets Manager (KMS-encrypted) |
| TUF root / targets keys | Decide what every verifier trusts | Offline hardware tokens, 2 of 3 |
| TUF online key | Freshness of trust metadata | AWS KMS |
| Fulcio OIDC configuration | Decides who can obtain certificates | Git (Helm values), Argo CD |
| Transparency history | Detection and audit | Aurora MySQL |
| Kyverno policies | Decide what runs | Git, Argo CD |

## 2. Threats and controls

| # | Threat | Control | Detect |
|---|---|---|---|
| T1 | Theft of the CA private key | Non-exportable KMS key; key policy allows `kms:Sign` only to the Fulcio IRSA role; SCPs deny key policy changes outside break-glass | CloudTrail alarm on any `Sign` not from the Fulcio role; on `PutKeyPolicy`, `ScheduleKeyDeletion`, `DisableKey` |
| T2 | Abuse of the Fulcio role to sign arbitrary certificates | Fulcio pods on a dedicated node group; Pod Security `restricted`; no `exec` RBAC for humans in `fulcio-system`; image pinned by digest and verified by Kyverno in the platform cluster too | CT log monitor: every certificate must match a valid identity pattern; alert on certificates for unexpected issuers or identities |
| T3 | Malicious workflow signs a bad image | Signing only via the reusable workflow; runner group restriction; branch protection and reviews; per-namespace identity policies | Rekor monitor: signatures by unexpected `githubWorkflowRepository`/ref |
| T4 | Stolen staff session signs an image | Staff identities not accepted in production namespaces by default; MFA upstream; 5-minute tokens | Rekor/CT monitor on e-mail identities; break-glass label alert |
| T5 | Trust distribution tampered | TUF signatures; offline targets keys; S3 Object Lock; replicas are untrusted storage | Freshness and version monitoring per replica; TUF client errors in Kyverno logs |
| T6 | Admission bypass | `failurePolicy: Fail`; HA Kyverno; exclusions limited and label-gated; Argo CD self-heal on policies | Policy reports; alert on webhook configuration changes; Kubernetes audit logs |
| T7 | Registry substitution (tag moved) | Policies verify digests; ECR tag immutability; Kyverno mutates tags to digests | Kyverno policy reports |
| T8 | Log tampering / split view | Append-only Trillian; Rekor checkpoints signed by KMS; periodic consistency-proof checks by an independent monitor; Aurora deletion protection and PITR | Monitor job fails on inconsistent checkpoints |
| T9 | Denial of service on signing | Private endpoints only; ALB + WAF rate limits; HPA on Fulcio and Rekor; KMS quota headroom | SLO alerts on signing latency and error rate |
| T10 | Supply chain of the platform itself | All platform images pinned by digest; mirrored to a private ECR; verified by Kyverno in the platform cluster; Renovate PRs for upgrades | Drift detection in Argo CD |

## 3. IAM summary

| Principal | Allowed | Explicitly denied |
|---|---|---|
| `fulcio` IRSA role (prod account) | `kms:Sign`, `kms:GetPublicKey`, `kms:DescribeKey` on the `fulcio-ca` key (by key ID after the second Terraform pass; by alias condition before) | everything else in KMS |
| `rekor` IRSA role | same, on `alias/sigstore/rekor` | |
| `tsa` IRSA role | same, on `alias/sigstore/tsa` | |
| `ctlog` IRSA role | `secretsmanager:GetSecretValue` on the CT key secret; `kms:Decrypt` on its encryption key | |
| `tuf-publisher` role | `kms:Sign` on `alias/sigstore/tuf-online`; `s3:PutObject` on the TUF bucket | `s3:DeleteObject*`, bypass governance |
| `sigstore-ceremony` role | `kms:GetPublicKey` on all signing keys; `kms:Sign` on CA and TSA keys **only inside the `ceremony_window`** set in the key policy | Assumable only from the IAM Identity Center ceremony permission set (MFA at sign-in), assigned to named operators |
| Break-glass role | Key policy administration | Use alarms immediately; requires two people |

Key policies are written so that the key administrator cannot also use the key, and the user role cannot administer it.

### 3.1 Accepted risks

| Risk | Why accepted | Compensating controls | Revisit when |
|---|---|---|---|
| Rekor's search-index connection to Aurora uses `tls=preferred`: encrypted, but the server certificate is not verified (`values/common/rekor.yaml`) | The Rekor chart cannot mount a CA bundle, and the go-sql-driver `tls=custom` option needs code registration. Trillian's own `--mysql_tls_ca` cannot be used either, because it appends `?tls=custom` to a DSN that already has `?` (trillian `storage/mysql/provider.go`); Trillian therefore uses `tls=true` with `SSL_CERT_FILE` and **does** verify | Path stays inside the VPC; Aurora security group admits only EKS node security groups; Aurora enforces `require_secure_transport`; the index holds no signatures (Trillian is the source of truth; a tampered index can only hide or mis-point search results, and every result is re-verified by the client) | The Rekor chart supports extra volumes for a CA bundle, or Rekor v2 (no MySQL index) is adopted |
| GitHub marks gitsign commits "Unverified" ([11-gitsign.md](11-gitsign.md)) | GitHub trusts only public CAs for S/MIME | `verify-commits` workflow required by organisation ruleset, verifying against the private trust root | GitHub supports custom CA trust for commit signatures |

## 4. Kubernetes hardening (platform cluster)

- EKS private API endpoint only; IRSA; managed node groups with Bottlerocket or AL2023, IMDSv2 hop limit 1.
- Pod Security Admission `restricted` on all Sigstore namespaces; read-only root filesystems; no service account token automount except where IRSA needs it.
- NetworkPolicies default-deny (VPC CNI network policy enforcement enabled): Trillian reachable only from Rekor and the CT log; Aurora security groups allow only the matching pod security groups (Security Groups for Pods).
- Secrets: External Secrets from Secrets Manager; etcd envelope encryption with a KMS key.
- Kyverno in the platform cluster verifies the platform's own images.

## 5. Monitoring the logs (detective control)

The transparency logs are only useful if someone watches them. Run a monitor (CronJob, every 15 minutes) that:

1. Fetches the latest Rekor checkpoint and verifies a consistency proof from the last stored checkpoint; stores the new one in S3.
2. Scans new Rekor entries and CT log entries since the last run; extracts certificate identity, issuer and GitHub extensions.
3. Alerts when an identity does not match the allow-list in `enterprise/policies/identities.yaml` (same source as the Kyverno policies), or when the issuer is anything other than the three configured issuers (GitHub enterprise, Keycloak `staff`, Keycloak `ci`).

Sigstore's open-source `rekor-monitor` covers steps 1–2 and is the recommended starting point.

## 6. Compliance mapping (summary)

| Control objective | Evidence produced |
|---|---|
| Only authorised builds reach production | Kyverno policy reports, admission audit logs |
| Key custody | KMS key policies, CloudTrail `Sign` events, ceremony records |
| Change management | Git history of policies and Fulcio config; Argo CD sync history |
| Non-repudiation of releases | Rekor entries with inclusion proofs; RFC 3161 timestamps |
| Segregation of duties | Separate PKI, platform and application roles; two-person rule on TUF targets and break-glass |
