# 10 Deployment Runbook

First installation of the private Sigstore platform, in order. Each step ends with a check; do not continue past a failed check. Run the whole runbook in a **sandbox account set** first (same Terraform, throwaway keys and a test root CA), then for staging and production.

Placeholders (`111111111111`, `222222222222`, `example-bank`, `sigstore.corp.example`, `REPLACE…`) are listed in [00-overview.md](00-overview.md) §4. `tools/validate.sh` must pass on the branch you deploy from.

## 0. Prerequisites

| Item | Owner | Check |
|---|---|---|
| Accounts: security (`111111111111`), Sigstore prod (`222222222222`), CI, workload accounts | Cloud platform | `aws organizations describe-account` for each |
| `me-south-1` opted in for the Sigstore and security accounts (opt-in Region) | Cloud platform | `aws account get-region-opt-status --region-name me-south-1` → `ENABLED` |
| Transit Gateway attachments allowed, central inspection VPC routes `0.0.0.0/0`, egress allowlist has `token.actions.githubusercontent.com` and `login.microsoftonline.com` | Network | Change ticket approved |
| Route 53 Resolver inbound endpoints for on-prem / Azure DNS forwarding of `sigstore.corp.example` | Network | `dig fulcio.sigstore.corp.example` from on-prem after step 2 |
| Terraform state buckets per account (versioned, encrypted, `use_lockfile`) | Cloud platform | `backend.hcl` filled per environment |
| GitHub Enterprise Cloud: enterprise-unique OIDC issuer **planned** with every team that has cloud OIDC trusts ([03-identity.md](03-identity.md) §1.1) | DevOps platform + IAM owners | Inventory signed off |
| GitHub organisation rulesets: `main` protected in every repository that deploys; `v*` tags creatable only by release managers; `platform-workflows` changes need platform review | DevOps platform | Rulesets visible in the org settings |
| Ceremony roles named; date booked; two root custodians available | Security / PKI | [02-pki-and-ceremony.md](02-pki-and-ceremony.md) §3 |
| Three TUF custodians with hardware tokens (YubiKey PIV, P-256 slot 9c) | Security / PKI | Each exports `tuf-cN.pub` |

## 1. Mirror images and charts

Nothing in the platform pulls from the internet. A connected build host mirrors every chart and image into the platform ECR, **by digest**, after verifying the upstream signature where the project publishes one.

```bash
# Charts → ECR (OCI). Versions are the pins in 01-architecture.md §4.
aws ecr get-login-password | helm registry login 222222222222.dkr.ecr.me-central-1.amazonaws.com --username AWS --password-stdin
for c in sigstore/fulcio:2.11.4 sigstore/rekor:1.8.7 sigstore/ctlog:0.2.69 sigstore/trillian:0.4.1 sigstore/tsa:2.1.5 \
         kyverno/kyverno:3.9.2 jetstack/cert-manager:v1.21.3 external-secrets/external-secrets:2.14.0 \
         awspca/aws-privateca-issuer:v1.11.1 eks/aws-load-balancer-controller:3.6.1; do
  helm pull "${c%%:*}" --version "${c##*:}"
done
for t in *.tgz; do helm push "$t" oci://222222222222.dkr.ecr.me-central-1.amazonaws.com/charts; done

# Images: list every image the rendered manifests reference, verify, copy by digest.
./tools/validate.sh                       # also leaves the renders in $WORK/render
grep -ho 'image: .*' "$WORK"/render/*.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cosign verify ghcr.io/sigstore/fulcio@sha256:2de0226c5f82008091a4c9de4f7b84b081f2bff1d13530d7f7357a6ba19d3835 \
  --certificate-identity-regexp '^https://github\.com/sigstore/fulcio/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com > /dev/null   # repeat per signed project
while read -r img; do crane copy "$img" "222222222222.dkr.ecr.me-central-1.amazonaws.com/mirror/${img#*/}"; done < images.txt
```

Enable ECR cross-Region replication of `mirror/*`, `charts/*` and `sigstore/*` to `me-south-1`. Build and push `enterprise/images/rekor-monitor` and `enterprise/images/runner`.

**Check:** `crane digest` of every mirrored image equals the upstream digest; ECR replication status `COMPLETE` in `me-south-1`.

## 2. Terraform (first pass)

Order matters because KMS key policies name IAM roles, and a key policy that names a role which does not exist is rejected ([enterprise/terraform/README.md](../terraform/README.md)).

```bash
cd enterprise/terraform/environments/platform-prod   # 1. IRSA roles, VPC, EKS, Aurora, TUF bucket (pca_arn empty)
terraform init -backend-config=backend.hcl && terraform apply
cd ../platform-dr                                     # 2. DR Region, joins the Aurora global clusters
terraform init -backend-config=backend.hcl && terraform apply -var private_zone_id=$(terraform -chdir=../platform-prod output -json platform | jq -r .zone_id)
cd ../security                                        # 3. keys (with ceremony_window), PCAs, roles
terraform init -backend-config=backend.hcl && terraform apply -var 'ceremony_window={start="2026-11-02T06:00:00Z",end="2026-11-02T14:00:00Z"}'
```

**Checks:**

```bash
aws kms describe-key --key-id alias/sigstore/fulcio-ca --query 'KeyMetadata.[KeySpec,KeyUsage,MultiRegion]'   # ECC_NIST_P384, SIGN_VERIFY, true
aws kms describe-key --key-id alias/sigstore/fulcio-ca --region me-south-1 --query KeyMetadata.MultiRegionConfiguration.MultiRegionKeyType  # REPLICA
aws acm-pca describe-certificate-authority --certificate-authority-arn "$(terraform output -raw pca_arn)" --query CertificateAuthority.Status  # PENDING_CERTIFICATE
aws eks describe-cluster --name sigstore-prod --query cluster.resourcesVpcConfig.endpointPublicAccess   # false
```

## 3. Key ceremony and PCA activation

Follow [02-pki-and-ceremony.md](02-pki-and-ceremony.md) §4–5 with the record template `enterprise/pki-ceremony/ceremony-log.md`. Outputs:

1. `fulcio-ca.crt`, `tsa.crt`, both chains, `root.crt` — verified with `verify-issued-cert.sh` (both PASS).
2. Both TLS subordinate CAs imported and `ACTIVE`:
   ```bash
   aws acm-pca import-certificate-authority-certificate --certificate-authority-arn "$PCA" \
     --certificate fileb://pca.crt --certificate-chain fileb://root.crt
   ```
3. `rekor.pub` exported: `aws kms get-public-key --key-id alias/sigstore/rekor --query PublicKey --output text | base64 -d | openssl pkey -pubin -inform DER -out enterprise/pki/rekor.pub`
4. CT log key generated, encrypted, and written to **both** Regions (the DR environment reads `sigstore-dr/…`):
   ```bash
   openssl ecparam -name prime256v1 -genkey -noout | openssl ec -aes256 -passout env:CTPASS -out ctlog.key
   openssl ec -in ctlog.key -passin env:CTPASS -pubout -out enterprise/pki/ctlog.pub
   v=$(jq -n --rawfile k ctlog.key --arg p "$CTPASS" '{private:$k,password:$p}')
   aws secretsmanager put-secret-value --secret-id sigstore-prod/ctlog/private-key --secret-string "$v"
   aws secretsmanager put-secret-value --secret-id sigstore-dr/ctlog/private-key --secret-string "$v" --region me-south-1
   shred -u ctlog.key
   ```
5. Close the window: PR with `ceremony_window = null`, `terraform apply` in `environments/security`.

**Check:** CloudTrail shows exactly two `kms:Sign` calls by `sigstore-ceremony` (the two CSRs); `aws kms get-key-policy` for `fulcio-ca` no longer contains `CeremonySignsCSRInWindow`.

## 4. Platform cluster

### 4.1 Terraform second pass

The security account now exists, so set in both platform environments' `terraform.tfvars` and apply:

- `pca_arn`: primary (`pca_arn`) and DR (`pca_dr_arn`) outputs of `environments/security`. This creates the ACM certificate for `*.sigstore.corp.example` and grants the cert-manager issuer role.
- `signing_key_ids`: the `key_ids` output (`{fulcio = "mrk-…", rekor = "mrk-…", tsa = "mrk-…"}`; a Multi-Region key and its replica share the ID). This narrows each IRSA role's `kms:Sign` from the alias-based condition used in the first pass to exactly one key.

```bash
terraform -chdir=../security output -json key_ids    # copy into signing_key_ids in platform-prod and platform-dr
```

**Checks:** `aws acm describe-certificate --certificate-arn … --query Certificate.[Status,RenewalEligibility]` → `ISSUED`, `ELIGIBLE`; `aws iam get-role-policy` (or the policy simulator) for `sigstore-prod-fulcio` shows `kms:Sign` on `key/mrk-…` with no `kms:ResourceAliases` condition. The smoke test (§6) is run only after this second pass.

### 4.2 Fill in the values

Replace every `REPLACE` in `enterprise/helm/values/{prod,dr}/`, `enterprise/helm/manifests/` and `enterprise/consumers/` with Terraform outputs and the public files from §3 (chains, `root.crt`, RDS CA bundle for both Regions). The CI job fails if `REPLACE` remains on `main` for an environment marked ready.

```bash
grep -rn REPLACE enterprise/helm enterprise/consumers enterprise/policies   # must print nothing before go-live
```

### 4.3 Database bootstrap

Terraform generated the Aurora master passwords (write-only, never in state) and stored them in Secrets Manager as `sigstore-prod/admin/mysql-master` and `sigstore-prod/admin/postgresql-master` (output `aurora_master_secret_arns`; RDS-managed master secrets are not supported for Aurora Global Database). Create one database user per service with its own password, store each in Secrets Manager under `sigstore-prod/app/<name>`, and load the Trillian schema. Run from the platform bastion (the cluster API and Aurora are private):

```bash
for s in trillian-db rekor-index-db keycloak-db; do
  aws secretsmanager create-secret --name "sigstore-prod/app/$s" --kms-key-id alias/… \
    --secret-string "$(jq -n --arg u "${s%%-*}" --arg p "$(openssl rand -base64 30)" '{username:$u,password:$p}')"
done
MASTER=$(terraform -chdir=enterprise/terraform/environments/platform-prod output -json platform | jq -r '.aurora_master_secret_arns.mysql')
# mysql client with TLS verification against the RDS bundle
mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca=me-central-1-bundle.pem -h "$MYSQL_HOST" -u admin_mysql -p"$(aws secretsmanager get-secret-value --secret-id "$MASTER" --query SecretString --output text | jq -r .password)" <<SQL
CREATE DATABASE IF NOT EXISTS trillian;  CREATE DATABASE IF NOT EXISTS rekor_index;
CREATE USER IF NOT EXISTS 'trillian'@'%' IDENTIFIED BY '<from sigstore-prod/app/trillian-db>' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'rekor'@'%'    IDENTIFIED BY '<from sigstore-prod/app/rekor-index-db>' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON trillian.* TO 'trillian'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX ON rekor_index.* TO 'rekor'@'%';
SQL
mysql … trillian < enterprise/vendor/trillian/storage-v1.8.0.sql     # schema of Trillian v1.8.0
# PostgreSQL: CREATE ROLE keycloak LOGIN PASSWORD '…'; CREATE DATABASE keycloak OWNER keycloak;
```

Rekor creates its `EntryIndex` table itself on first start (`pkg/indexstorage/mysql`, `CREATE TABLE IF NOT EXISTS`). The DR environment uses the same users and data through the Aurora global database; copy the three app secrets to `sigstore-dr/app/*` in `me-south-1`. Also create `sigstore-prod/app/keycloak-idp` (Entra/AD FS client values) and `sigstore-prod/app/keycloak-ci-clients` (one random secret per client in realm `ci`: keys `jenkins-prod`, `platform-release`), and copy both to `sigstore-dr/app/`.

**Check:** `SHOW TABLES FROM trillian` lists `Trees`, `Subtree`, `LeafData`, `SequencedLeafData`, `TreeHead`, `Unsequenced`, `TreeControl`.

### 4.4 Argo CD and the platform

Install Argo CD (mirrored chart) in the platform cluster, register the Git repository and the ECR OCI chart repository, then:

```bash
kubectl apply -f enterprise/gitops/platform/project.yaml -f enterprise/gitops/platform/apps-prod.yaml
argocd app wait -l app.kubernetes.io/instance --health --timeout 1800
```

Sync waves bring up controllers → secrets and issuers → Keycloak operator → Trillian → Keycloak, TUF mirror, monitor → Fulcio, Rekor, TSA → CT log. Keycloak imports realms `staff` (people, brokered from Entra ID / AD FS) and `ci` (service-account clients for non-GitHub CI, `realm-ci.yaml`).

**Checks:**

```bash
kubectl -n trillian-system get lease                                    # one holder for the log signer election
kubectl -n fulcio-system logs deploy/fulcio-server | grep -i 'kms\|error' | head
curl -s --cacert root.crt https://fulcio.sigstore.corp.example/api/v2/configuration | jq '.issuers[].issuerUrl'
curl -s --cacert root.crt https://rekor.sigstore.corp.example/api/v1/log | jq '{treeID,treeSize}'
curl -s --cacert root.crt https://tsa.sigstore.corp.example/api/v1/timestamp/certchain | openssl x509 -noout -subject
curl -s --cacert root.crt https://ctlog.sigstore.corp.example/sigstore/ct/v1/get-sth | jq .tree_size
curl -s -o /dev/null -w '%{http_code}\n' --cacert root.crt -X POST https://ctlog.sigstore.corp.example/sigstore/ct/v1/add-chain   # 404: not routed
curl -s --cacert root.crt https://id.sigstore.corp.example/realms/staff/.well-known/openid-configuration | jq -r .issuer
```

### 4.5 Pin the tree IDs

The first sync created one Trillian tree for Rekor and one for the CT log. Commit their IDs so a re-sync can never create another, and DR uses the same logs:

```bash
kubectl -n rekor-system get cm rekor-config -o jsonpath='{.data.treeID}'     # → values/prod/rekor.yaml server.config.treeID
kubectl -n ctlog-system get cm ctlog-config -o jsonpath='{.data.treeID}'     # → values/prod/ctlog.yaml server.config.treeID
```

## 5. Publish trust (TUF)

Custodian ceremony with `enterprise/tuf/tufctl.py` ([04-trust-distribution.md](04-trust-distribution.md)); the repository lives in `example-bank/sigstore-trust`.

```bash
cosign trusted-root create \
  --fulcio "url=https://fulcio.sigstore.corp.example,certificate-chain=enterprise/pki/fulcio-chain.pem" \
  --rekor  "url=https://rekor.sigstore.corp.example,public-key=enterprise/pki/rekor.pub,start-time=$REKOR_START" \
  --ctfe   "url=https://ctlog.sigstore.corp.example,public-key=enterprise/pki/ctlog.pub,start-time=$CT_START" \
  --tsa    "url=https://tsa.sigstore.corp.example/api/v1/timestamp,certificate-chain=enterprise/pki/tsa-chain.pem" \
  --out trusted_root.json
cosign signing-config create \
  --fulcio "url=https://fulcio.sigstore.corp.example,api-version=1,start-time=$NOW,operator=example-bank" \
  --rekor  "url=https://rekor.sigstore.corp.example,api-version=1,start-time=$NOW,operator=example-bank" --rekor-config ANY \
  --oidc-provider "url=https://id.sigstore.corp.example/realms/staff,api-version=1,start-time=$NOW,operator=example-bank" \
  --tsa    "url=https://tsa.sigstore.corp.example/api/v1/timestamp,api-version=1,start-time=$NOW,operator=example-bank" --tsa-config EXACT:1 \
  --out signing_config.v0.2.json
aws kms get-public-key --key-id alias/sigstore/tuf-online --query PublicKey --output text | base64 -d | openssl pkey -pubin -inform DER -out online.pub
python3 enterprise/tuf/tufctl.py init --repo repo --root-key tuf-c1.pub --root-key tuf-c2.pub --root-key tuf-c3.pub --online-pub online.pub
python3 enterprise/tuf/tufctl.py add-target --repo repo trusted_root.json signing_config.v0.2.json
python3 enterprise/tuf/tufctl.py sign --repo repo --role root    --signer "hsm:" --pub tuf-c1.pub   # custodian 1
python3 enterprise/tuf/tufctl.py sign --repo repo --role targets --signer "hsm:" --pub tuf-c1.pub
# … custodian 2 the same; then merge: tuf-publish.yml signs snapshot/timestamp and uploads
```

`$REKOR_START` and `$CT_START` are the creation times of the two trees (§4.5); `$NOW` is the publication time. Commit `repo/publish/1.root.json` as `enterprise/tuf/root/1.root.json`: it is the file every client pins (Kyverno `tuf.root.data` is its base64; runner and laptop images bake it in).

**Check:** `python3 enterprise/tuf/tufctl.py verify --repo repo --root enterprise/tuf/root/1.root.json` passes; `curl https://tuf.sigstore.corp.example/timestamp.json`, `https://tuf-az…`, `https://tuf-onprem…` all return the same `version`.

## 6. Smoke test

Run against prod (or DR after failover, [08-operations-dr.md](08-operations-dr.md) §5). Use a dedicated repository `example-bank/sigstore-smoke` that calls the reusable workflow, and a canary namespace on one cluster per platform.

| # | Test | Command / action | Expected |
|---|---|---|---|
| 1 | Pipeline signing | Push to `main` of `sigstore-smoke` (calls `sign.yml`) | Job green; summary shows the signed digest |
| 2 | Certificate identity | `cosign verify $IMG --certificate-identity https://github.com/example-bank/platform-workflows/.github/workflows/sign.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com/example-bank --certificate-github-workflow-repository example-bank/sigstore-smoke` | `Verification for … --` and checks listed |
| 3 | Wrong identity fails | Same with `--certificate-github-workflow-repository example-bank/other` | Non-zero exit |
| 4 | Transparency | `rekor-cli search --rekor_server https://rekor.sigstore.corp.example --sha $DIGEST` then `rekor-cli get --uuid …` | Entry with the workflow certificate |
| 5 | CT | `get-sth` tree size increased by one after test 1 | Yes |
| 6 | Staff signing | `cosign sign --fulcio-auth-flow device $IMG2` as a test user brokered from Entra ID | Certificate SAN is the user's e-mail; issuer `…/realms/staff` |
| 7 | Admission, signed | `verify-cluster.sh $IMG@$DIGEST $UNSIGNED@$DIGEST https://tuf.sigstore.corp.example sigstore-canary` on EKS, AKS, OpenShift, on-prem | PASS on each (with the policy in Audit, the denial check is reported, not enforced) |
| 8 | Promotion | Run `promote.yml` to ACR and Harbor | Destination verifies; test 7 passes on AKS/on-prem with the promoted reference |
| 9 | Monitor | `kubectl -n sigstore-monitor logs deploy/rekor-monitor` | Consistency proof verified for the new tree size |
| 10 | Commit signing | On a workstation set up per [11-gitsign.md](11-gitsign.md) §2: signed commit in `sigstore-smoke`, open a PR | `gitsign verify` prints the three `Validated … true` lines; the ruleset-required `verify-commits` workflow passes; an unsigned commit, a local commit with author `49699333+dependabot[bot]@users.noreply.github.com`, and a commit made through the REST Contents API (`PUT /repos/…/contents/…`) with that author (GitHub-signed, committer `web-flow`) all fail it |
| 11 | Trust freshness | `curl -s https://tuf.sigstore.corp.example/timestamp.json \| jq -r .signed.expires` | ≥ 6 days ahead |

Record the results in the change ticket. A failure in tests 2–3 or 7 blocks go-live.

## 7. Onboard consumer clusters

Register each cluster in the central Argo CD with label `sigstore.example-bank.com/platform=<eks|aks|openshift|onprem>`; the ApplicationSets in `enterprise/gitops/consumers/` install Kyverno and the platform's policy overlay. Start in Audit ([09-rollout-plan.md](09-rollout-plan.md)), then run test 7 of §6.

## 8. Rollback

| Stage | Rollback |
|---|---|
| Terraform | `terraform apply` of the previous commit. Signing keys cannot be scheduled for deletion (key policy Deny), Aurora has deletion protection, and the TUF bucket has Object Lock; review any plan that replaces these before applying. |
| Argo CD sync | Revert the commit; Argo CD self-heals to it. Tree IDs and data are unaffected. |
| Policies | Set `validationActions: [Audit]` in one commit; break-glass label for a single namespace. |
| Trust (TUF) | Publish targets that restore the previous `trusted_root.json` (custodians sign a new targets version; versions only move forward). |
