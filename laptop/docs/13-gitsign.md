# 13 — Signing git commits and tags with gitsign

cosign signs **images**. [gitsign](https://github.com/sigstore/gitsign) signs **git commits and tags** with the same keyless flow and the same private services: you log in to Keycloak, Fulcio issues a 10-minute certificate for your e-mail address, git signs the commit with a throw-away key, and the signature is recorded in your private Rekor. There is no GPG or SSH key to create, protect or revoke.

Version in the kit: **gitsign v0.18.0** (`GITSIGN_VERSION` in `config/env.sh`; `scripts/01-build-offline-bundle.sh` downloads it into `bundle/bin/` and checks it against the release's `checksums.txt`, because gitsign releases have no sigstore bundle). Windows: `WITH_WINDOWS_CLI=1` also fetches `bundle/bin/windows/gitsign.exe`, checked the same way. `checksums.txt` is not signed, so this proves the download is intact, not who published it; record the SHA-256 values once and compare them on later builds.

## 1. How gitsign finds your private trust root

gitsign does **not** read `trusted_root.json`. It reads:

| What | Variable | File the kit writes |
|---|---|---|
| Fulcio CA chain | `GITSIGN_FULCIO_ROOT` | `out/gitsign/fulcio-chain.pem` |
| Rekor public key (one key) | `SIGSTORE_REKOR_PUBLIC_KEY` | `out/gitsign/rekor.pub` |
| CT log public key (one key) | `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE` | `out/gitsign/ctlog.pub` |

`scripts/export-trust.sh` creates these files, and `out/gitsign/gitsign.env` exporting the variables, **from `trusted_root.json`**, so cosign, Kyverno and gitsign always trust the same keys. Without these variables gitsign falls back to the public-good Sigstore, cannot reach it offline, and would not trust your CA anyway.

## 2. Set up

The stack must be running (`scripts/install-all.sh`) and the TUF mirror published (step 12).

```bash
cd ~/sigstore-offline
export PATH="$PWD/bundle/bin:$PATH"
source out/cosign.env                       # SSL_CERT_FILE etc.
scripts/14-configure-gitsign.sh --global    # or: scripts/14-configure-gitsign.sh path/to/repo
source out/gitsign/gitsign.env              # in every shell that signs or verifies
git config --global user.email alice@sigstore.local
```

Expected:

```text
==> Fetching trust from https://tuf.sigstore.local and exporting it for gitsign
==> Configuring git (--global) in .
 ✔  gitsign configured. Next:
```

What the script sets, and why:

| git config | Value | Why |
|---|---|---|
| `gpg.format` / `gpg.x509.program` | `x509` / `gitsign` | git calls gitsign to sign and to verify |
| `commit.gpgsign`, `tag.gpgsign` | `true` | sign every commit and annotated tag |
| `gitsign.fulcio`, `gitsign.rekor` | `https://fulcio.sigstore.local`, `https://rekor.sigstore.local` | your private services |
| `gitsign.issuer`, `gitsign.clientID` | `https://keycloak.sigstore.local/realms/sigstore`, `sigstore` | your Keycloak realm and its public client |
| `gitsign.redirectURL` | `http://localhost:8765/auth/callback` | a redirect URI registered on the Keycloak client |
| `gitsign.rekorMode` | `offline` | stores the Rekor inclusion proof in the commit, so verification needs no call to Rekor |
| `gitsign.matchCommitter` | `true` | refuses to sign when `user.email` differs from the certificate's e-mail |

## 3. Sign and verify

```bash
git commit -m "my first signed commit"      # browser opens: log in as alice (password: grep DEMO_USER_PASSWORD pki/secrets.env)
git tag -m "v0.1.0" v0.1.0
gitsign verify --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore HEAD
```

Expected (from the kit's integration test):

```text
tlog index: 4
gitsign: Signature made using certificate ID 0x6401b830… | CN=Sigstore Offline Fulcio Intermediate CA,OU=Code Signing,O=Sigstore Offline Lab
gitsign: Good signature from [alice@sigstore.local](https://keycloak.sigstore.local/realms/sigstore)
Validated Git signature: true
Validated Rekor entry: true
Validated Certificate claims: true
```

```bash
gitsign verify-tag --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore v0.1.0
git verify-commit HEAD          # git runs gitsign for you
git log --show-signature -1
```

`git verify-commit` and `git log --show-signature` cannot pass an expected identity, so they end with `Validated Certificate claims: false` and `WARNING: git verify-commit does not verify cert claims. Prefer using `gitsign verify` instead.` They prove the signature and the Rekor entry, not **who** signed. Anything that gates (CI, release scripts) must use `gitsign verify --certificate-identity …`.

**Prove the negative:** `gitsign verify --certificate-identity mallory@sigstore.local …` must fail, and so must any verification in a shell where `gitsign.env` is not sourced.

Headless shells: `git config gitsign.tokenProvider device` uses the device-code flow (enabled on the kit's Keycloak client). Scripts and CI can write a token to `/var/run/sigstore/cosign/oidc-token` (**without** a trailing newline) and set `gitsign.tokenProvider filesystem`, as `test/compose/gitsign-test.sh` does.

## 4. Things to know

- **GitHub and gitlab.com show "Unverified".** They check X.509 (S/MIME) commit signatures only against public CAs. Your private Fulcio CA is not one, so the badge is expected; verify with `gitsign verify` (in CI, as a workflow the platform enforces — see `enterprise/docs/11-gitsign.md` §3). Do not turn on GitHub's "Require signed commits" for these repositories: it would reject them. Self-managed GitLab checks X.509 signatures against its own system trust store, so adding your Fulcio root there makes them show as Verified.
- **`user.email` in lower case.** Keycloak lower-cases e-mails and `matchCommitter` compares case-sensitively.
- **One Rekor key and one CT key.** The two `SIGSTORE_*` variables take exactly one key, so `export-trust.sh` exports the active one. After a log-key rotation, commits signed under the old key still verify with cosign but not with gitsign.
- **Privacy.** Your e-mail address is in the certificate and in the Rekor entry. That is fine in a private log; be careful before pointing gitsign at a public one.
- **Merges and squashes made by a Git server** are not signed by gitsign.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `error: gpg failed to sign the data` | gitsign failed; git hides why | `GITSIGN_LOG=/tmp/gitsign.log git commit …` then read the log |
| `invalid header field value for "Authorization"` | token file ends with a newline | write it with `printf '%s'` |
| `tls: failed to verify certificate: x509: certificate signed by unknown authority` | `SSL_CERT_FILE` not set | `source out/cosign.env` |
| `error getting certificate root: initializing tuf: … tuf-repo-cdn.sigstore.dev` | `gitsign.env` not sourced, so gitsign looks for the public Sigstore | `source out/gitsign/gitsign.env` |
| `gitsign.matchCommitter: certificate identity does not match config - want Alice <bob@…>, got email: [alice@…]` | `user.email` differs from your login e-mail | set `user.email` to your login e-mail |
| `no matching CertificateIdentity found, last error: expected SAN value "mallory@…", got "alice@…"` | verified with the wrong `--certificate-identity` | correct identity (this is the negative test working) |
| `redirect_uri` error in the browser | `gitsign.redirectURL` not registered | keep `http://localhost:8765/auth/callback` |

## 6. Tested

`test/compose/run.sh` runs `test/compose/gitsign-test.sh` in the air-gapped toolbox: signed commit and tag, `gitsign verify` (all three "Validated … true" lines), `verify-tag`, `git verify-commit` (signature and Rekor entry; certificate claims reported as not checked), wrong identity rejected, and verification without the private trust files rejected. The same test first runs `scripts/14-configure-gitsign.sh` to set up git, and checks that `matchCommitter` refuses to sign with a mismatched `user.email`. See [11-test-report.md](11-test-report.md).
