#!/usr/bin/env bash
# =============================================================================
# 11-inspect-rekor.sh — show what the private transparency log recorded.
#
#   scripts/11-inspect-rekor.sh            # log info + the last 3 entries
#   scripts/11-inspect-rekor.sh 5          # last 5 entries
#   scripts/11-inspect-rekor.sh --index 0  # one specific entry
#
# Uses Rekor's REST API only (curl + jq + openssl), so it works without
# rekor-cli. Everything shown comes from the Rekor + Trillian + MySQL that run
# on this laptop; nothing is fetched from rekor.sigstore.dev.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd curl jq openssl base64
CURL=(curl -fsS --cacert "$(tls_ca)")

log "Log state: ${REKOR_URL}/api/v1/log"
INFO="$("${CURL[@]}" "${REKOR_URL}/api/v1/log")"
echo "$INFO" | jq '{treeSize, rootHash, treeID, signedTreeHead: (.signedTreeHead | split("\n")[0:3])}'
SIZE="$(echo "$INFO" | jq -r .treeSize)"
[[ "$SIZE" -gt 0 ]] || { warn "log is empty — sign something first (10-sign-and-verify.sh)"; exit 0; }

show_entry() {
  local idx="$1" e uuid body kind cert
  e="$("${CURL[@]}" "${REKOR_URL}/api/v1/log/entries?logIndex=${idx}")"
  uuid="$(echo "$e" | jq -r 'keys[0]')"
  body="$(echo "$e" | jq -r '.[].body' | base64 -d)"
  kind="$(echo "$body" | jq -r '.kind + "/" + .apiVersion')"
  echo "────────────────────────────────────────────────────────────"
  echo "$e" | jq -r --arg k "$kind" '.[] | "logIndex       : \(.logIndex)\nkind           : \($k)\nintegratedTime : \(.integratedTime | todate)\nlogID          : \(.logID)"'
  echo "uuid           : ${uuid}"
  echo "$body" | jq -r '
     (.spec.data.hash // .spec.payloadHash // .spec.envelopeHash // {}) as $h
     | "artifact hash  : \($h.algorithm // "-"):\($h.value // "-")"'
  # Extract the signing certificate (location differs per entry kind).
  cert="$(echo "$body" | jq -r '
      .spec.signature.publicKey.content            # hashedrekord
      // .spec.signatures[0].verifier              # dsse
      // .spec.publicKey                           # intoto
      // empty' 2>/dev/null | head -1)"
  if [[ -n "$cert" ]]; then
    echo "$cert" | base64 -d 2>/dev/null | openssl x509 -noout \
      -subject -issuer -startdate -enddate -ext subjectAltName 2>/dev/null \
      | sed 's/^/  cert: /'
  fi
  echo "$e" | jq -r '.[] | "inclusion proof: \(.verification.inclusionProof.hashes | length) hashes, checkpoint signed by log"'
}

if [[ "${1:-}" == "--index" ]]; then
  show_entry "${2:?index}"
else
  N="${1:-3}"
  for ((i = SIZE - 1; i >= 0 && i >= SIZE - N; i--)); do show_entry "$i"; done
fi
echo "────────────────────────────────────────────────────────────"
ok "Entries are persisted in MySQL (namespace trillian-system, PVC trillian-mysql)"
