# Security

## Reporting

Report a suspected vulnerability or key compromise to the Security Operations Centre
(`soc@example-bank.com`, 24×7) and open a confidential incident; do not open a public issue.
For key compromise follow the playbooks in `enterprise/docs/08-operations-dr.md` §6.

## What this repository may contain

Only public material: certificates, public keys, TUF metadata, configuration and code.
Private keys, passwords, Secrets Manager values, Terraform state and tfvars with real
values must never be committed. CI runs gitleaks on every pull request, and
`.gitignore` blocks key and state files.

## Changes that need Security / PKI approval

See `.github/CODEOWNERS`: PKI and TUF material, the KMS and Private CA Terraform,
the security account, admission policies, the signing workflows and the Fulcio
issuer configuration.
