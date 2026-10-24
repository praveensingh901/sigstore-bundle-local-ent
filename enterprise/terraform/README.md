# Terraform: Sigstore platform on AWS

| Path | Account | What it creates |
|---|---|---|
| `modules/kms-signing-keys` | security | Multi-Region KMS signing keys (Fulcio CA, TSA, Rekor, TUF online) with sign-only key policies and a ceremony window |
| `modules/private-ca` | security | AWS Private CA subordinate for TLS (pending until the offline root signs it), RAM share |
| `modules/platform` | Sigstore | VPC (TGW egress, no IGW), endpoints with org-only policies, DNS Firewall allowlist, EKS, Aurora MySQL + PostgreSQL, IRSA roles, CT key secret, TUF bucket, ACM certificate, ALB security groups |
| `environments/security` | 111111111111 | keys, two PCAs (primary and DR Region), ceremony and TUF publisher roles |
| `environments/platform-prod` | 222222222222 / me-central-1 | platform + Aurora global clusters |
| `environments/platform-dr` | 222222222222 / me-south-1 | warm standby joining the global clusters |

## Apply order (first install)

1. `platform-prod` (IRSA role ARNs must exist before key policies name them; `pca_arn` empty).
2. `platform-dr` (same, `pca_arn` empty).
3. `security` with `ceremony_window` set.
4. Key ceremony and PCA import ([02-pki-and-ceremony.md](../docs/02-pki-and-ceremony.md) §4–5); then `security` again with `ceremony_window = null`.
5. `platform-prod` and `platform-dr` again with `pca_arn` set (ACM certificate).

Full sequence with checks: [10-deployment-runbook.md](../docs/10-deployment-runbook.md).

```bash
cd environments/platform-prod
cp backend.hcl.example backend.hcl; cp terraform.tfvars.example terraform.tfvars   # edit placeholders
terraform init -backend-config=backend.hcl
terraform plan -out tfplan && terraform apply tfplan
```

## Static checks (run in CI)

```bash
terraform fmt -check -recursive
for d in modules/private-ca modules/platform environments/*; do (cd $d && terraform init -backend=false && terraform validate); done
tflint --init && tflint --recursive --config "$PWD/.tflint.hcl"
checkov -d . --config-file .checkov.yaml
```

`modules/kms-signing-keys` declares a `aws.dr` provider alias, so it is validated through `environments/security` rather than on its own.
These checks were run on this code (terraform 1.13.4, tflint 0.59.1 with ruleset-aws 0.50.0, checkov 3.3.30: 0 failed, 40 skipped with reasons). Nothing here has been applied to a real account; run the smoke test in the runbook in a sandbox account first.
