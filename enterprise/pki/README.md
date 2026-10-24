# enterprise/pki — public trust material

Only **public** files live here. They are produced at the key ceremony
([02-pki-and-ceremony.md](../docs/02-pki-and-ceremony.md) §4.5) and committed through a pull request
that needs PKI and platform approvals (CODEOWNERS).

| File | Content | Consumed by |
|---|---|---|
| `root.crt` | Corporate offline root (public certificate) | Fulcio `ca-cert`, Keycloak truststore, Kyverno `caCertificates`, runner images |
| `fulcio-ca.crt` | Sigstore Code-Signing CA | trusted root |
| `fulcio-chain.pem` | `fulcio-ca.crt` + `root.crt` | Fulcio `kms_cert_chain`, `cosign trusted-root create --fulcio` |
| `tsa.crt`, `tsa-chain.pem` | Timestamping certificate, + root | TSA `cert_chain`, trusted root |
| `rekor.pub` | Rekor KMS public key (`aws kms get-public-key`) | trusted root |
| `ctlog.pub` | CT log public key | trusted root |
| `CEREMONY-<date>.md` | Signed ceremony record (template: `../pki-ceremony/ceremony-log.md`) | audit |

Never commit private keys, passwords, or Secrets Manager values. The repository
`.gitignore` blocks `*.key`, `*.p12`, `*.pfx` and `*.enc.key` under this folder.
