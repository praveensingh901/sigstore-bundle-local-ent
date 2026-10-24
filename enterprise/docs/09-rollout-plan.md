# 09 Rollout Plan

## 1. Phases

| Phase | Weeks | Deliverable | Exit criteria |
|---|---|---|---|
| 0. Decisions and ceremony prep | 1–2 | D1–D5 decided ([00-overview.md](00-overview.md) §5); ceremony roles named; GitHub enterprise-unique issuer change planned with IAM owners | Signed decision log; ceremony date booked |
| 1. Foundations | 2–3 | Security and Sigstore accounts, network, KMS keys, AWS Private CA; **key ceremony**; EKS + Aurora in dev and staging | `verify-issued-cert.sh` passes for CA and TSA; dev platform smoke test green |
| 2. Pilot | 3–4 | Prod platform; reusable signing workflow; 3 pilot repositories signing; Kyverno in **Audit** on 2 clusters (1 EKS, 1 AKS) | 100% of pilot images signed for 2 weeks; zero false positives in policy reports; DR test passed once |
| 3. Adoption | 4–8 | All GitHub repositories that deploy to Kubernetes call the reusable workflow; Audit on every cluster including OpenShift and on-prem; promotion workflow copies signatures | ≥ 95% of running images in Audit reports pass |
| 4. Enforcement | 2 per tier | `Deny` by tier: dev → staging → non-critical prod → critical prod; team policies narrow identities | Each tier 2 weeks without unplanned denials; break-glass tested once per tier |
| 5. Operate | ongoing | Monitoring, rotation calendar, quarterly DR and access reviews | SLOs met; audit evidence produced on request |

## 2. RACI

| Activity | Security / PKI | Cloud platform | DevOps platform | App teams | Cluster owners |
|---|---|---|---|---|---|
| Key ceremony, TUF custodians | **A/R** | C | I | — | — |
| AWS accounts, network, EKS, Aurora | C | **A/R** | I | — | — |
| Fulcio/Rekor/CT/TSA/Keycloak operation | C | **A/R** | C | — | — |
| Reusable signing workflow, runners | C | C | **A/R** | I | — |
| Calling the workflow, fixing failures | — | — | C | **A/R** | — |
| Kyverno install and policies | **A** (policy content) | C | C | I | **R** |
| Exceptions and break-glass | **A** | R | C | C | R |

## 3. Communication

- Before phase 2: engineering-wide note on what signing means for teams (nothing changes in their repository except calling one workflow).
- Before each enforcement tier: list of namespaces with failing images from policy reports, sent to owners 2 weeks ahead.
- Training: the Sigstore Academy course (`tutorial/`) for platform and DevOps engineers; a 30-minute session for app teams on reading a denial message.

## 4. Risks

| Risk | Mitigation |
|---|---|
| Enabling the enterprise-unique GitHub issuer breaks existing cloud OIDC trusts | Inventory all IAM OIDC providers and federated credentials first; add the new issuer before the switch ([03-identity.md](03-identity.md) §1.1) |
| Vendor images without signatures | Import workflow scans and re-signs them; third-party policy accepts only that workflow |
| Fail-closed outage from Kyverno | 3 replicas + PDB; namespace exclusions for system components; runbook to switch a policy to Audit in one commit |
| TUF expiry because the refresh job failed | 7-day timestamps refreshed every 6 h; alert at 3 days |
| AD CS root cannot apply the requested extensions | Validate in a test ceremony on a test root first; `verify-issued-cert.sh` blocks bad certificates |
