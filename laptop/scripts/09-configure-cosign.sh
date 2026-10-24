#!/usr/bin/env bash
# =============================================================================
# 09-configure-cosign.sh — build the client trust store for the PRIVATE stack.
#
# Produces (in out/):
#   trusted_root.json    WHAT to trust: Fulcio CA chain, Rekor key, CT log key.
#                        Format: application/vnd.dev.sigstore.trustedroot+json
#   signing_config.json  WHERE to sign: Fulcio URL, Rekor URL, OIDC issuer URL.
#   ca-bundle.pem        system CAs + our TLS root (for SSL_CERT_FILE)
#   cosign.env           `source out/cosign.env` to configure a shell
#
# cosign v3 reads these via --trusted-root / --signing-config. Nothing is ever
# fetched from the public Sigstore TUF repository, which is what makes the
# workflow work with no internet.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd cosign
[[ -f "${PKI_DIR}/meta.env" ]] || die "run 03-generate-pki.sh first"
# shellcheck disable=SC1091
source "${PKI_DIR}/meta.env"
mkdir -p "${OUT_DIR}"

T="${TRUST_START_TIME}"
CT_URL="http://ctlog.ctlog-system.svc/${CTLOG_PREFIX}"   # informational only

log "Creating ${OUT_DIR}/trusted_root.json"
cosign trusted-root create \
  --fulcio "url=${FULCIO_URL},certificate-chain=${PKI_DIR}/fulcio/chain.pem" \
  --rekor  "url=${REKOR_URL},public-key=${PKI_DIR}/rekor/rekor.pub,start-time=${T}" \
  --ctfe   "url=${CT_URL},public-key=${PKI_DIR}/ctlog/ctlog.pub,start-time=${T}" \
  --out "${OUT_DIR}/trusted_root.json"

log "Creating ${OUT_DIR}/signing_config.json"
cosign signing-config create \
  --fulcio "url=${FULCIO_URL},api-version=1,start-time=${T},operator=${SIGSTORE_OPERATOR}" \
  --rekor  "url=${REKOR_URL},api-version=1,start-time=${T},operator=${SIGSTORE_OPERATOR}" \
  --rekor-config ANY \
  --oidc-provider "url=${OIDC_ISSUER},api-version=1,start-time=${T},operator=${SIGSTORE_OPERATOR}" \
  --out "${OUT_DIR}/signing_config.json"

log "Creating ${OUT_DIR}/ca-bundle.pem (system roots + private TLS root)"
: >"${OUT_DIR}/ca-bundle.pem"
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [[ -f "$f" ]] && { cat "$f" >>"${OUT_DIR}/ca-bundle.pem"; break; }
done
cat "$(tls_ca)" >>"${OUT_DIR}/ca-bundle.pem"

cat >"${OUT_DIR}/cosign.env" <<EOF
# source this file:  source out/cosign.env
# Paths are resolved relative to this file, so the kit folder can be moved.
# Linux/WSL: Go programs (cosign, crane) use SSL_CERT_FILE instead of the OS store.
# Windows-native cosign.exe ignores SSL_CERT_FILE: import pki/tls/ca.crt into
# "Trusted Root Certification Authorities" instead (windows/Setup-Hosts.ps1).
_sigstore_out="\$(cd "\$(dirname "\${BASH_SOURCE[0]:-\$0}")" && pwd)"
export SSL_CERT_FILE="\${_sigstore_out}/ca-bundle.pem"
export SIGSTORE_TRUSTED_ROOT="\${_sigstore_out}/trusted_root.json"
export SIGSTORE_SIGNING_CONFIG="\${_sigstore_out}/signing_config.json"
export SIGSTORE_OIDC_ISSUER="${OIDC_ISSUER}"
export SIGSTORE_OIDC_CLIENT_ID="${OIDC_CLIENT_ID}"
export SIGSTORE_OIDC_REDIRECT_URL="${OIDC_REDIRECT_URL}"
export SIGSTORE_REKOR_URL="${REKOR_URL}"
export SIGSTORE_FULCIO_URL="${FULCIO_URL}"
unset _sigstore_out
EOF

ok "Client trust material ready:"
cosign_summary() {
  jq -r '"  Fulcio CAs : \(.certificateAuthorities | length)  (\(.certificateAuthorities[0].uri))",
         "  Rekor logs : \(.tlogs | length)  (\(.tlogs[0].baseUrl))",
         "  CT logs    : \(.ctlogs | length)  (\(.ctlogs[0].baseUrl))"' "${OUT_DIR}/trusted_root.json"
}
command -v jq >/dev/null && cosign_summary || true
echo "  next: source ${OUT_DIR}/cosign.env && scripts/10-sign-and-verify.sh"
