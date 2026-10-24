# 05 Consumer Clusters: EKS, AKS, OpenShift, on-prem

Every cluster enforces the same rule with the same tool: **Kyverno `ImageValidatingPolicy`** ([ADR-0007](../../docs/adr/0007-kyverno-on-all-platforms.md)). A cluster needs three things and no connection to the Sigstore platform:

1. Kyverno 1.19.x with the corporate root CA in its trust bundle.
2. The policy pack from `enterprise/policies/kyverno/`, rendered with the cluster's nearest TUF replica.
3. Pull access to the registry that holds the images **and** their signature bundles.

## 1. Install (all platforms)

Argo CD application per cluster, chart `kyverno/kyverno` 3.9.2, values `enterprise/helm/values/common/kyverno.yaml`:

| Setting | Value | Why |
|---|---|---|
| `admissionController.replicas` | 3 + PodDisruptionBudget | Fail-closed webhook must stay available |
| `global.caCertificates.data` | corporate root CA (PEM) | Kyverno must trust TLS of the TUF replica and private registries |
| `config.webhooks.namespaceSelector` | `NotIn`: `kube-system`, `kyverno` and the platform namespaces of each distribution (e.g. `openshift-*` are listed explicitly) | Never send control-plane Pods to the webhook (the chart default excludes only `kube-system`; `config.resourceFiltersExcludeNamespaces` does the opposite, it removes namespaces from Kyverno's built-in filters) |
| `admissionController.container.resources` | 500m / 512Mi requests | Signature verification is CPU-bound |
| `features.policyReports` | enabled | Audit mode findings per namespace |

## 2. Registry access for signatures

Kyverno fetches the bundle from the same repository as the image. Configure credentials in the policy (`spec.credentials`):

| Platform | Registry | Kyverno credentials | Node / IAM setup |
|---|---|---|---|
| EKS | ECR | `providers: [amazon]` | Kyverno service account with an IAM role (IRSA or EKS Pod Identity) allowing `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on the repositories |
| AKS | ACR | `providers: [azure]` | Kyverno workload identity with `AcrPull` on the registry |
| OpenShift | Quay / Harbor / ACR / ECR | `secrets: [<pull secret>]` or provider | Pull secret in the Kyverno namespace |
| On-prem | Harbor | `secrets: [harbor-robot]` | Harbor robot account with pull on the projects |

**Promotion must copy signatures.** When an image moves from ECR to ACR or Harbor, copy it with its referrers: `oras cp -r <src>@<digest> <dst>`. Do not use `cosign copy` for v3 bundles; it copies only the legacy signature tags. A plain `docker pull/push` loses the bundle and the image will be denied. The promotion workflow in `enterprise/ci/promote.yml` does this and verifies the copy.

## 3. Policy pack

| File | Kind | Scope | What it requires |
|---|---|---|---|
Files in `enterprise/policies/kyverno/`, rendered per platform by `enterprise/consumers/<platform>/kustomization.yaml` (TUF replica, registry, credentials):

| File | Kind | Scope | What it requires |
|---|---|---|---|
| `allowed-registries.yaml` | `ValidatingPolicy` | Every Pod (containers, init and ephemeral) | Image comes from the platform's approved registry; otherwise it would bypass the signature policies, which match by registry |
| `baseline.yaml` | `ImageValidatingPolicy` | Every namespace except break-glass and staff opt-in namespaces | Signed by one of the two central reusable workflows (`sign.yml`, `import-third-party.yml` on `main`), verified through your TUF root; tags are resolved to digests by Kyverno |
| `teams/team-*.yaml` | `NamespacedImageValidatingPolicy` | One team's namespace | Stricter: only the team's repository (`githubWorkflowRepository`) and `refs/heads/main`. Deployed by the team's Argo CD project |
| `third-party.yaml` | `ImageValidatingPolicy` | `vendor/` repositories | Signature from the **import** workflow only, which scans and re-signs vendor images after review |
| `staff-signed-optin.yaml` | `ImageValidatingPolicy` | Namespaces labelled `sigstore.example-bank.com/allow-staff-signatures: "true"` (excluded from the baseline) | The central workflows **or** e-mail identities from the staff realm (break-glass) |
| `protect-labels.yaml` | `ValidatingPolicy` (Deny from day one) | Namespaces | Only the platform Argo CD may set or change the break-glass and opt-in labels |
| `../identities.yaml` | data | — | The allow-list the policies and the log monitors are generated from |

All policies use `validationActions: [Audit]` in rollout phase 2 and `[Deny]` from phase 4 ([09-rollout-plan.md](09-rollout-plan.md)). Every policy must pass, so a team policy can only narrow the baseline.

Break-glass: namespaces with label `sigstore.example-bank.com/enforce: "off"` are excluded by `matchConstraints.namespaceSelector`. Only the platform team's Argo CD project can set that label (RBAC + a Kyverno `ValidatingPolicy` that blocks anyone else from adding it), and its presence pages the security on-call.

## 4. Platform notes

### 4.1 EKS (AWS)

- TUF mirror: `https://tuf.sigstore.corp.example` (Route 53 private zone associated with the workload VPC).
- Workload VPC needs HTTPS to that ALB through Transit Gateway; nothing else from the Sigstore VPC.
- ECR repositories: enable **tag immutability** and scan on push; signatures attach as referrers.

### 4.2 AKS (Azure)

- TUF mirror: `https://tuf-az.sigstore.corp.example`. Azure Storage cannot serve HTTPS for a custom domain itself (it presents its `*.web.core.windows.net` certificate), so an **internal Application Gateway** (private frontend IP, certificate for `tuf-az.sigstore.corp.example` from the corporate PKI in Key Vault) fronts the storage account's static-website endpoint, which is reachable only through its private endpoint. Azure Private DNS resolves the name to the gateway. The replication job copies the S3 tree after every publish.
- ACR replicates within Azure natively (geo-replication); signatures copied in by the promotion workflow travel with it as referrers.
- Azure Policy and Ratify are not required; Kyverno is the single enforcer.

### 4.3 OpenShift (on-prem or Azure Red Hat OpenShift)

Kyverno is the enforcer here as well. OpenShift's native `ClusterImagePolicy` (`config.openshift.io/v1`) cannot be the main control:

| Limitation | Evidence |
|---|---|
| `fulcioSubject` has only `oidcIssuer` and `signedEmail` (exact match, must look like an e-mail) | `openshift/api` `config/v1/types_image_policy.go`, `PolicyFulcioSubject` |
| GitHub workflow certificates carry a **URI** SAN, so they can never match `signedEmail` | Fulcio `subject-alternative-name-template` for GitHub; `containers/container-libs` `image/signature/fulcio_cert.go` checks `EmailAddresses` only |
| CRI-O looks for signatures only under the `sha256-<digest>.sig` tag; cosign v3 stores bundles as OCI referrers by default | `containers/container-libs` `image/docker/docker_client.go`, `sigstoreAttachmentTag` |

**Optional second layer:** for platform images signed by a Keycloak **service identity with an e-mail SAN**, you can also sign in the legacy format (`cosign sign --new-bundle-format=false …`, deprecated in cosign 3 but still available) and add a native `ClusterImagePolicy` for those repositories. Treat it as defence in depth, and plan its removal if cosign drops the legacy format.

Install Kyverno into OpenShift with the same chart; verify it runs under the `restricted-v2` SCC in a test cluster first (`oc adm policy who-can use scc` and the admission pod's `openshift.io/scc` annotation).

### 4.4 On-prem Kubernetes

- TUF mirror: `https://tuf-onprem.sigstore.corp.example` served by an nginx next to Harbor, refreshed by the replication job over Direct Connect.
- Harbor 2.x supports OCI referrers; keep **tag immutability** on and retain untagged artifacts (signature bundles are untagged).

## 5. Verifying a cluster is protected

```bash
# 1. policy is ready
kubectl get imagevalidatingpolicy baseline-signed-by-central-workflow -o jsonpath='{.status.conditionStatus.ready}'
# 2. a signed image is admitted (server-side dry run, nothing is created)
kubectl -n demo run ok --image=<registry>/demo/hello@sha256:<signed digest> --dry-run=server
# 3. an unsigned copy is denied
kubectl -n demo run bad --image=<registry>/demo/unsigned@sha256:<digest> --dry-run=server
# 4. trust material is fresh (TUF timestamp expiry > 3 days)
curl -s https://<tuf replica>/timestamp.json | jq -r .signed.expires
```

`enterprise/consumers/verify-cluster.sh` runs these four checks and exits non-zero on any failure; schedule it from each cluster's monitoring.
