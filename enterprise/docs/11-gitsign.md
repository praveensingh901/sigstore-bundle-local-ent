# 11 Source Signing with gitsign

Image signatures (06) prove **which workflow built an image**. gitsign proves **who wrote each commit and tag** that went into it, with the same keyless model: an engineer logs in through Keycloak, Fulcio issues a 10-minute certificate for their e-mail address, the commit is signed with a throw-away key, and the signature is recorded in the private Rekor. No GPG or SSH signing keys exist to manage, lose or revoke.

| | Image signing (cosign) | Commit signing (gitsign) |
|---|---|---|
| Signer | `sign.yml` workflow (GitHub OIDC) | Engineer (Keycloak `staff` realm, via Entra ID / AD FS) |
| Certificate SAN | workflow URI | `name@example-bank.com` |
| Stored | bundle as OCI referrer next to the image | S/MIME (CMS) signature in the commit object; Rekor entry |
| Enforced by | Kyverno at admission | workflow `verify-commits` required by an organisation ruleset |

Version: **gitsign v0.18.0** (signing path uses sigstore-go; Rekor v1 API by default).

## 1. How trust works for gitsign

gitsign does not read `trusted_root.json`. It takes its Fulcio CA chain from `GITSIGN_FULCIO_ROOT` (or from legacy TUF targets such as `fulcio.crt.pem`), and the Rekor and CT log keys from `SIGSTORE_REKOR_PUBLIC_KEY` and `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE` (`internal/fulcio/fulcioroots`, `cosign.GetRekorPubs`, `cosign.GetCTLogPubs`). To keep **one** source of truth, those files are generated from the `trusted_root.json` that every client already receives through TUF:

```bash
cosign initialize --mirror https://tuf.sigstore.corp.example --root /etc/sigstore/tuf-root.json
export-trust.sh ~/.sigstore/root/tuf.sigstore.corp.example/targets/trusted_root.json ~/.config/sigstore-trust
source ~/.config/sigstore-trust/gitsign.env
```

`export-trust.sh` (in `laptop/scripts/`, baked into the runner image) writes `fulcio-chain.pem`, `rekor.pub`, `ctlog.pub`, `tsa-chain.pem` and `gitsign.env`. The two `SIGSTORE_*` variables accept exactly **one** key each, so the script exports the active key (the last one without an end time). During a Rekor or CT key rotation, commits signed under the old key verify with cosign but not with gitsign until the overlap ends; schedule log-key rotations accordingly ([02-pki-and-ceremony.md](02-pki-and-ceremony.md) §7).

## 2. Engineer set-up (once per machine)

Distribute through the standard workstation configuration (Intune / Jamf / dotfiles), or let engineers run it:

```bash
# gitsign binary from the internal mirror (checksum-verified, see enterprise/images/runner/fetch-tools.sh)
git config --global gpg.format x509
git config --global gpg.x509.program gitsign
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gitsign.fulcio https://fulcio.sigstore.corp.example
git config --global gitsign.rekor https://rekor.sigstore.corp.example
git config --global gitsign.issuer https://id.sigstore.corp.example/realms/staff
git config --global gitsign.clientID sigstore
git config --global gitsign.redirectURL http://localhost:8765/auth/callback   # the redirect URI registered in Keycloak
git config --global gitsign.rekorMode offline           # inclusion proof stored in the commit; verify needs no Rekor call
git config --global gitsign.matchCommitter true          # refuse to sign if user.email differs from the certificate
```

On Windows use the `gitsign_0.18.0_windows_amd64.exe` release and the same `git config` commands in PowerShell. Go on Windows uses the Windows certificate store (not `SSL_CERT_FILE`), so the corporate root must be there for TLS to `*.sigstore.corp.example` (it is, on managed devices). `export-trust.sh` is bash: the Intune profile distributes the three trust files (generated centrally from the current `trusted_root.json`) to `C:\ProgramData\Sigstore\` and sets the user environment variables `GITSIGN_FULCIO_ROOT`, `SIGSTORE_REKOR_PUBLIC_KEY` and `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE` to them; engineers can also run `export-trust.sh` in Git Bash or WSL and set the variables with `setx`.

The first commit opens a browser to `id.sigstore.corp.example`, which sends the engineer to Entra ID (or AD FS); MFA happens there. Headless sessions (remote SSH, dev containers) use `git config gitsign.tokenProvider device` for the device-code flow.

`git config user.email` must match the corporate e-mail address **exactly and in lower case** (Keycloak lower-cases e-mails, and `matchCommitter` compares case-sensitively), because the certificate carries the address from the identity provider; `gitsign.matchCommitter` makes gitsign refuse to sign when they differ. Without a cache every commit opens a login; engineers who commit often can run the optional `gitsign-credential-cache` daemon (shipped in the same release) and point `GITSIGN_CREDENTIAL_CACHE` at its socket, so the short-lived key and certificate are reused while the certificate is valid.

## 3. Verifying

```bash
gitsign verify --certificate-identity jane.doe@example-bank.com \
  --certificate-oidc-issuer https://id.sigstore.corp.example/realms/staff HEAD
# tlog index: 1234
# gitsign: Signature made using certificate ID 0x… | CN=sigstore-intermediate,…
# gitsign: Good signature from [jane.doe@example-bank.com](https://id.sigstore.corp.example/realms/staff)
# Validated Git signature: true
# Validated Rekor entry: true
# Validated Certificate claims: true
gitsign verify-tag --certificate-identity-regexp '^[a-z0-9._-]+@example-bank\.com$' \
  --certificate-oidc-issuer https://id.sigstore.corp.example/realms/staff v1.4.0
git verify-commit HEAD     # signature + Rekor only: prints "Validated Certificate claims: false"
```

`git verify-commit` cannot pass an expected identity to gitsign, so it does not check **who** signed. Every gate (the PR check, release scripts) uses `gitsign verify` with `--certificate-identity[-regexp]` and `--certificate-oidc-issuer`.

**Pull requests:** `enterprise/ci/verify-commits.yml` verifies every commit between the PR base and head (and in the merge queue, with the merge method) and fails on any commit that is not gitsign-signed by an `@example-bank.com` identity from the `staff` realm. Enforce it with the organisation ruleset rule **"Require workflows to pass before merging"**, pointing at the file in `example-bank/platform-workflows` at a pinned commit. Do **not** enforce it as a required status check by name: the caller workflow would come from the pull request itself, which could skip the verification and still report a green check.

Two exceptions, both decided by facts GitHub or git computes, never by the free-text author e-mail (which anyone can set):

| Exception | Accepted only if |
|---|---|
| Bot commits (Dependabot, Renovate) | GitHub API reports the commit `verification.verified: true`; the author **account** is in `ALLOWED_BOT_LOGINS`; the **committer is that same bot account** (not `web-flow`: GitHub signs web-UI and REST-API commits whose author field anyone can set); and the pull request was opened by that bot. Renovate qualifies only when it runs as a GitHub App with `platformCommit` enabled, and `ALLOWED_BOT_LOGINS` must hold that app's actual login (a self-hosted app is `<app-name>[bot]`, not `renovate[bot]`). |
| "Update branch" merge commits | committer `web-flow`, GitHub-verified, two parents, and the commit tree equals `git merge-tree --write-tree <parent1> <parent2>`: the merge adds nothing. A merge with web-UI conflict resolution contains new content and fails: rebase locally and sign. `git merge-tree` may rarely differ from GitHub's server-side merge on unusual renames; the check then fails closed (rebase locally). |

If the repository uses a merge queue, set its merge method to **merge**: with squash or rebase the queue creates new GitHub-signed commits that the check rejects. Use "Update with merge" (or rebase locally), not "Update with rebase".

The job runs on the `sigstore-verify` runner scale set (same image, no network path to Fulcio or Rekor): pull requests are untrusted input and must not share the signing pool. Verification needs only TUF and git.

The check proves that each commit was signed by *some* engineer; it does not bind the signer to the commit's author or committer fields (gitsign `matchCommitter` does that at signing time on the engineer's machine). Code review remains the control for who wrote what.

**Why not GitHub's "Require signed commits" rule:** GitHub verifies S/MIME commit signatures only against public certificate authorities, so commits signed by the private Fulcio CA appear as **Unverified** in the GitHub UI and that rule would reject them. The ruleset-required workflow is the enforcement point; the "Unverified" badge is expected and should be explained to engineers.

## 4. What gitsign does not do

- It does not replace image signing: a signed commit can still produce an unsigned or tampered image. Both controls are needed.
- Merge, squash and **rebase-and-merge** commits created on `main` by GitHub are re-created and signed with GitHub's own key, not gitsign. The PR's own commits are what the check verifies; protect `main` so only merges of verified PRs land.
- Rekor entries contain the signer's e-mail address. The log is private, so this stays inside the bank (decision D5).

## 5. Tested

`laptop/test/compose/run.sh` signs a commit and a tag with gitsign v0.18.0 against the private Fulcio, Rekor and CT log, with trust exported from the TUF-distributed `trusted_root.json`, and checks that: `gitsign verify` and `verify-tag` pass for the right identity; `git verify-commit` verifies the signature and Rekor entry (and reports that it did not check certificate claims); a wrong identity is rejected; and verification fails without the private trust files.
