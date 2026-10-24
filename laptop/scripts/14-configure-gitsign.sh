#!/usr/bin/env bash
# 14-configure-gitsign.sh — set up keyless git commit/tag signing with gitsign
# against the private Fulcio + Rekor (docs/13-gitsign.md).
#
#   scripts/14-configure-gitsign.sh [REPO_DIR]     configure one repository
#   scripts/14-configure-gitsign.sh --global       configure ~/.gitconfig
#
# Then, in every shell that signs or verifies:  source out/gitsign/gitsign.env
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd git gitsign cosign jq openssl

SCOPE=(--local); TARGET="${1:-.}"
if [[ "${1:-}" == "--global" ]]; then SCOPE=(--global); TARGET="."; fi
export SSL_CERT_FILE="${SSL_CERT_FILE:-${OUT_DIR}/ca-bundle.pem}"

# 1. Trust: gitsign does not read trusted_root.json, so derive the files it does
#    read from the TUF-distributed trusted_root.json (one source of truth).
log "Fetching trust from ${TUF_URL} and exporting it for gitsign"
cosign initialize --mirror "${TUF_URL}" --root "${OUT_DIR}/tuf/root.json" >/dev/null
# cosign keeps one directory per mirror (host[-port]); take OURS, never a public-good one.
TUF_DIR="${TUF_URL#https://}"; TUF_DIR="${TUF_DIR%%/*}"; TUF_DIR="${TUF_DIR//:/-}"
TR="$HOME/.sigstore/root/${TUF_DIR}/targets/trusted_root.json"
[[ -s "$TR" ]] || TR="${OUT_DIR}/trusted_root.json"    # TUF not published yet: use the local copy
"$(dirname "$0")/export-trust.sh" "$TR" "${OUT_DIR}/gitsign" >/dev/null
echo "trust source: $TR"

# 2. git configuration
log "Configuring git (${SCOPE[*]}) in ${TARGET}"
cd "$TARGET"
g() { git config "${SCOPE[@]}" "$@"; }
g gpg.format x509
g gpg.x509.program gitsign
g commit.gpgsign true
g tag.gpgsign true
g gitsign.fulcio "${FULCIO_URL}"
g gitsign.rekor "${REKOR_URL}"
g gitsign.issuer "${OIDC_ISSUER}"
g gitsign.clientID "${OIDC_CLIENT_ID}"
g gitsign.redirectURL "http://localhost:8765/auth/callback"   # registered on the Keycloak client
g gitsign.rekorMode offline        # inclusion proof stored in the commit: verify works without Rekor
g gitsign.matchCommitter true      # refuse to sign if user.email differs from the certificate

ok "gitsign configured. Next:"
echo "  source ${OUT_DIR}/gitsign/gitsign.env"
echo "  git config ${SCOPE[*]} user.email ${DEMO_USER_EMAIL}"
echo "  git commit -m 'my first signed commit'      # browser opens: log in as ${DEMO_USER}"
echo "  gitsign verify --certificate-identity ${DEMO_USER_EMAIL} --certificate-oidc-issuer ${OIDC_ISSUER} HEAD"
