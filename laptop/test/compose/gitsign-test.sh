#!/usr/bin/env bash
# Runs INSIDE the air-gapped toolbox (test/compose/run.sh): signs and verifies
# git commits and tags with gitsign against the private Fulcio + Rekor + CT log.
# Trust comes from the TUF-distributed trusted_root.json (scripts/export-trust.sh).
set -Eeuo pipefail
source scripts/lib.sh
export SSL_CERT_FILE=/kit/out/ca-bundle.pem HOME=/tmp/gitsign-home
mkdir -p "$HOME"
# Decoy: a public-good TUF cache that sorts BEFORE ours ("tuf-repo…" < "tuf.…").
# The configure script must still pick the private mirror's trusted_root.json.
mkdir -p "$HOME/.sigstore/root/tuf-repo-cdn.sigstore.dev/targets"
echo '{"decoy":"public-good"}' >"$HOME/.sigstore/root/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json"

R="$HOME/repo"; git init -q "$R"
scripts/14-configure-gitsign.sh "$R" >"$HOME/configure.log"   # the documented set-up path
# shellcheck disable=SC1091
source "${OUT_DIR}/gitsign/gitsign.env"
grep -q "BEGIN CERTIFICATE" "$GITSIGN_FULCIO_ROOT"      # private chain, not the decoy
# …and taken from the private TUF mirror's cache, not the local fallback copy.
grep -qx "trust source: $HOME/.sigstore/root/${TUF_HOST}/targets/trusted_root.json" "$HOME/configure.log"
echo "  14-configure-gitsign.sh: trust exported from the private TUF mirror"

# Non-interactive login for the test: gitsign's "filesystem" token provider
# reads /var/run/sigstore/cosign/oidc-token (a person would use the browser).
mkdir -p /var/run/sigstore/cosign
# No trailing newline: gitsign sends the file verbatim as the bearer token.
printf '%s' "$(scripts/get-token.sh user)" >/var/run/sigstore/cosign/oidc-token
USER_ID="${DEMO_USER}@${DOMAIN}"

cd "$R"
git config user.name "Alice"; git config user.email "$USER_ID"
git config gitsign.tokenProvider filesystem
[[ "$(git config gitsign.rekorMode)" == offline && "$(git config gitsign.matchCommitter)" == true ]]

echo hello >README.md; git add README.md
git commit -q -m "signed commit" 2>"$HOME/commit.log" || { cat "$HOME/commit.log"; exit 1; }
git tag -m "v0.1.0" v0.1.0 2>>"$HOME/commit.log"
echo "  commit and tag signed"

gitsign verify --certificate-identity "$USER_ID" --certificate-oidc-issuer "$OIDC_ISSUER" HEAD >"$HOME/verify.log" 2>&1 \
  || { cat "$HOME/verify.log"; exit 1; }
grep -q "Validated Git signature: true" "$HOME/verify.log"
grep -q "Validated Rekor entry: true" "$HOME/verify.log"
grep -q "Validated Certificate claims: true" "$HOME/verify.log"
echo "  gitsign verify HEAD: signature, Rekor entry and identity OK"
gitsign verify-tag --certificate-identity "$USER_ID" --certificate-oidc-issuer "$OIDC_ISSUER" v0.1.0 >/dev/null 2>&1
echo "  gitsign verify-tag OK"
# git cannot pass an expected identity, so gitsign checks signature + Rekor
# only and says so. Gates must use "gitsign verify --certificate-identity".
git verify-commit HEAD >"$HOME/vc.log" 2>&1 || { cat "$HOME/vc.log"; exit 1; }
grep -q "Validated Rekor entry: true" "$HOME/vc.log"
grep -q "git verify-commit does not verify cert claims" "$HOME/vc.log"
echo "  git verify-commit HEAD OK (signature + Rekor; identity not checked, as gitsign warns)"

if gitsign verify --certificate-identity "mallory@${DOMAIN}" --certificate-oidc-issuer "$OIDC_ISSUER" HEAD >/dev/null 2>&1; then
  echo "FAIL: wrong identity accepted"; exit 1; fi
echo "  wrong identity rejected"

git config user.email "bob@${DOMAIN}"; echo more >>README.md; git add README.md
if GITSIGN_LOG="$HOME/mc.log" git commit -q -m "should not sign" 2>/dev/null; then
  echo "FAIL: matchCommitter signed for a different user.email"; exit 1; fi
grep -q "gitsign.matchCommitter: certificate identity does not match" "$HOME/mc.log"
git config user.email "$USER_ID"; git reset -q --hard
echo "  matchCommitter refuses to sign with a mismatched user.email"

# Public-good trust must NOT accept our commit: drop the private trust files.
if env -u GITSIGN_FULCIO_ROOT -u SIGSTORE_REKOR_PUBLIC_KEY -u SIGSTORE_CT_LOG_PUBLIC_KEY_FILE HOME=/tmp/empty-home \
     gitsign verify --certificate-identity "$USER_ID" --certificate-oidc-issuer "$OIDC_ISSUER" HEAD >/dev/null 2>&1; then
  echo "FAIL: verified without the private trust root"; exit 1; fi
echo "  verification without the private trust root fails, as it must"
