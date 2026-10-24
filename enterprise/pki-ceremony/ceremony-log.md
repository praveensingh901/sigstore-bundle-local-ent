# Key Ceremony Record — Sigstore Code-Signing CA, TSA, TLS subordinate CAs

Copy this file to `enterprise/pki/CEREMONY-<YYYY-MM-DD>.md`, fill it in during the ceremony, and have every participant sign the printed copy. Procedure: [02-pki-and-ceremony.md](../docs/02-pki-and-ceremony.md) §4–5.

## 1. Participants

| Role | Name | Organisation unit | Signature |
|---|---|---|---|
| Ceremony lead (PKI) | | | |
| Root key custodian 1 | | | |
| Root key custodian 2 | | | |
| AWS operator (`sigstore-ceremony` role) | | | |
| Witness / recorder (Security or Audit) | | | |

## 2. Preconditions

| Check | Result | Time (UTC) | Initials |
|---|---|---|---|
| Ceremony PR merged: `ceremony_window` set to this session (start/end) | | | |
| `terraform apply` of `environments/security` shows the window in the four key policies | | | |
| Ceremony workstation booted from the approved image; network: AWS only (no internet) | | | |
| `kms-csr` binary SHA-256 matches the signed release: `__________` | | | |
| `openssl version` = 3.x, GNU coreutils present | | | |
| Offline root online on its air-gapped host; HSM/tokens present | | | |
| CloudTrail alarm on `kms:Sign` by the ceremony role acknowledged by SOC | | | |

## 3. Certificate requests

| Step | Command (abbreviated) | Output SHA-256 | Result | Time | Initials |
|---|---|---|---|---|---|
| Caller identity is `sigstore-ceremony` | `aws sts get-caller-identity` | — | | | |
| Fulcio CA CSR | `kms-csr --profile fulcio-ca …` | | | | |
| TSA CSR | `kms-csr --profile tsa …` | | | | |
| TLS PCA CSR (primary) | `terraform output -raw pca_csr` | | | | |
| TLS PCA CSR (DR) | `terraform output -raw pca_dr_csr` | | | | |
| `verify-csr.sh fulcio-ca.csr fulcio-ca awskms:///…` | | — | PASS / FAIL | | |
| `verify-csr.sh tsa.csr tsa awskms:///…` | | — | PASS / FAIL | | |

Media used to carry CSRs to the root (serial): `__________`

## 4. Issuance at the offline root

| Request | Root RequestId / serial | Issued cert SHA-256 | Time | Custodians |
|---|---|---|---|---|
| Fulcio CA (`[sigstore_ca]`) | | | | |
| TSA (`[sigstore_tsa]`) | | | | |
| TLS PCA primary (`[tls_subordinate]`) | | | | |
| TLS PCA DR (`[tls_subordinate]`) | | | | |

## 5. Verification of issued certificates

| Check | Result | Time | Initials |
|---|---|---|---|
| `verify-issued-cert.sh fulcio-ca fulcio-ca.crt root.crt awskms:///…` | PASS / FAIL | | |
| `verify-issued-cert.sh tsa tsa.crt root.crt awskms:///…` | PASS / FAIL | | |
| PCA certificates imported (`aws acm-pca import-certificate-authority-certificate`), status ACTIVE (both Regions) | | | |
| `rekor.pub` exported (`aws kms get-public-key`), SHA-256: `__________` | | | |
| CT log key generated (`openssl ec -aes256`), stored in Secrets Manager in **both** Regions (`sigstore-prod/ctlog/private-key`, `sigstore-dr/ctlog/private-key`); `ctlog.pub` SHA-256: `__________`; workstation copy shredded | | | |

## 6. Close-out

| Step | Result | Time | Initials |
|---|---|---|---|
| Public files committed in PR `#____` (`enterprise/pki/`) with PKI + platform approvals | | | |
| Follow-up PR sets `ceremony_window = null`; `terraform apply` done; key policies show no ceremony `Sign` | | | |
| CloudTrail: list of every `kms:Sign` by the ceremony role attached (expected: exactly 2) | | | |
| Workstation wiped / media sealed (bag number `______`) | | | |

## 7. Deviations

Record anything that differed from the procedure, who approved it and why.

| # | Deviation | Approved by | Impact |
|---|---|---|---|
| | | | |
