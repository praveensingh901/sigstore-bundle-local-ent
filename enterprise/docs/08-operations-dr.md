# 08 Operations and Disaster Recovery

## 1. Service levels

| Service | SLO | Measured by |
|---|---|---|
| Signing (Fulcio + Rekor) | 99.9% of signing requests succeed, monthly | Fulcio `/api/v2/signingCert` and Rekor `POST /api/v1/log/entries` 5xx rate |
| Signing latency | p95 < 2 s for certificate issuance | Fulcio request duration |
| Trust freshness | TUF timestamp never closer than 3 days to expiry | Freshness probe per replica |
| Verification | Kyverno admission p99 < 3 s | Kyverno metrics per cluster |

Verification availability does not depend on the signing platform; a full outage of the Sigstore account stops new signatures only.

## 2. Monitoring

| Signal | Source | Alert |
|---|---|---|
| Fulcio certificates issued | Fulcio metrics (`:2112`) | Drop to 0 during working hours; spike above baseline ×3 |
| Fulcio / Rekor 5xx | ALB and service metrics | > 1% for 5 min |
| KMS `Sign` throttling | CloudWatch `ThrottlingException` count | Any |
| Trillian sequencing lag | Trillian log signer metrics | > 60 s |
| Aurora replica lag (DR) | CloudWatch | > 5 s |
| TUF expiry per replica | Probe | < 3 days |
| Certificate expiry: Code-Signing CA, TSA, PCA subordinate | Scheduled check | < 180 days |
| Log consistency | `rekor-monitor` | Any failure |
| Kyverno webhook failures | Kyverno metrics per cluster | Any sustained |

## 3. Routine operations

| Task | Frequency | How |
|---|---|---|
| Upgrades (charts, images) | Monthly window | Renovate PR → dev → staging → prod via Argo CD; images mirrored and verified first |
| TUF snapshot/timestamp refresh | Every 6 h, automatic | `tuf-publish` scheduled workflow in the `sigstore-trust` repository (`enterprise/ci/tuf-publish.yml`), then `tuf-replicate.yml` to Azure and on-prem |
| TUF targets re-sign (expiry) | Every 5 months | Custodian ceremony (2 of 3) |
| DR test | Quarterly | §5 |
| Restore test of Aurora snapshots | Quarterly | Restore into an isolated account and run consistency checks |
| Access review (ceremony, break-glass, Keycloak admins) | Quarterly | IAM Access Analyzer + Keycloak export |

## 4. Backup

| Data | Mechanism | Retention |
|---|---|---|
| Aurora MySQL (Trillian trees, Rekor index) | Continuous backup (PITR 35 days) + daily snapshot copied to the DR Region and to a backup vault with AWS Backup Vault Lock | 35 days PITR; snapshots 1 year; yearly snapshot 10 years (audit) |
| Aurora PostgreSQL (Keycloak) | Same | 35 days / 1 year |
| Tree IDs | Stored in Git (`server.config.treeID` in `enterprise/helm/values/prod/rekor.yaml` and `prod/ctlog.yaml`) after first install; DR inherits them | Forever |
| TUF repository | S3 versioning + Object Lock; replicas | Forever |
| Configuration | Git | Forever |
| KMS keys | Multi-Region replicas in the DR Region (same key material, same public key) | Life of the key |

The transparency history is the only data that cannot be recreated. Everything else can be rebuilt from Git and KMS.

## 5. Disaster recovery

**Targets:** RPO ≤ 1 minute for the logs (Aurora Global Database); RTO ≤ 1 hour for signing. Verification has no RTO because it never depended on the Region.

**DR topology:** warm standby in `me-south-1`: EKS cluster deployed by the same Terraform and Argo CD with Sigstore workloads scaled to zero; Aurora Global Database secondary; KMS multi-Region replica keys; Route 53 failover records for `*.sigstore.corp.example`.

**Failover runbook (Region loss):**

1. Declare the incident; freeze changes.
2. Promote the Aurora global secondary (`aws rds failover-global-cluster` for a planned switch, or detach-and-promote for an unplanned Regional outage).
3. Scale up Sigstore workloads in the DR cluster: one PR that sets the replica counts in `enterprise/helm/values/dr/*.yaml`, `createctconfig.enabled: true` in `dr/ctlog.yaml`, Keycloak `instances` and the rekor-monitor replicas in `helm/manifests/overlays/dr/services`; Fulcio, Rekor and TSA use the replica KMS keys, which have the **same key material**, so certificates and checkpoints remain valid under the existing trusted root.
4. Fail over Route 53 records.
5. Run the smoke test from [10-deployment-runbook.md](10-deployment-runbook.md) §6 against the DR endpoints.
6. Verify log continuity: the Rekor checkpoint after failover must be consistent with the last checkpoint stored by the monitor.

Because the Trillian tree IDs, keys and data are the same, no client changes anything.

## 6. Key compromise playbooks

| Compromised | Immediate action | Recovery |
|---|---|---|
| Code-Signing CA (KMS key misuse) | Disable the key (`kms:DisableKey`) → Fulcio stops issuing | New key + ceremony; trusted root gets the old CA `end-time` = first misuse time from CloudTrail; publish via TUF; review every certificate issued after that time in the CT log |
| Rekor key | Disable key | New key; trusted root lists old key with end-time; investigate entries after compromise |
| CT log key | Rotate secret; restart CT log | Trusted root update via TUF |
| TUF online key | Disable key | Root update (2 of 3) replacing the online key |
| A TUF offline key | — | Root rotation by the other two custodians |
| GitHub enterprise / workflow | Disable the workflow, revoke runner registration | Policies: remove the identity; consider a trusted-root end-time only if the CA itself was abused |

## 7. Capacity

Plan for ≥ 3× the expected peak signing rate. Each signature costs at least two KMS `Sign` calls (Fulcio certificate, Rekor checkpoint/SET) and ≈2–4 KB across Aurora tables. Review KMS request quotas for asymmetric ECC signing in the security account before onboarding large build farms.
