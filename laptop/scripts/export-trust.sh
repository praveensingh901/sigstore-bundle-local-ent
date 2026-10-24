#!/usr/bin/env bash
# =============================================================================
# scripts/export-trust.sh <trusted_root.json> <out-dir>
#
# Writes the PEM files that tools without trusted_root.json support need, taken
# from the SAME trusted_root.json that cosign and Kyverno get through TUF:
#   fulcio-chain.pem   every Fulcio CA certificate (intermediates + roots)
#   rekor.pub          the active Rekor public key
#   ctlog.pub          the active CT log public key
#   tsa-chain.pem      Timestamp Authority chain(s), if any
#   gitsign.env        GITSIGN_FULCIO_ROOT / SIGSTORE_REKOR_PUBLIC_KEY /
#                      SIGSTORE_CT_LOG_PUBLIC_KEY_FILE pointing at the files
# gitsign v0.18 reads its Fulcio roots from TUF *legacy* targets (fulcio.crt.pem)
# or from GITSIGN_FULCIO_ROOT, and Rekor/CT keys from the two SIGSTORE_* files;
# it does not read trusted_root.json. This bridge keeps one source of truth.
# Get trusted_root.json from TUF first: `cosign initialize --mirror … --root …`
# leaves it in ~/.sigstore/root/<mirror>/targets/trusted_root.json.
# Needs: jq, base64, openssl.
# =============================================================================
set -Eeuo pipefail
TR="${1:?trusted_root.json}"; OUT="${2:?output dir}"; mkdir -p "$OUT"
der2pem() { base64 -d | openssl "$1" -inform DER "${@:2}"; }

: >"$OUT/fulcio-chain.pem"
jq -r '.certificateAuthorities[].certChain.certificates[].rawBytes' "$TR" | while read -r c; do
  printf '%s' "$c" | der2pem x509 >>"$OUT/fulcio-chain.pem"; done
# cosign/gitsign read exactly ONE key from SIGSTORE_REKOR_PUBLIC_KEY and
# SIGSTORE_CT_LOG_PUBLIC_KEY_FILE, so export the active key: the last entry
# without a validFor.end. During a key rotation, signatures made under the
# old key verify with cosign/Kyverno (trusted_root.json) but not with gitsign.
active() { jq -r "[.$1[] | select(.publicKey.validFor.end == null)] | last | .publicKey.rawBytes" "$TR"; }
active tlogs  | der2pem pkey -pubin >"$OUT/rekor.pub"
active ctlogs | der2pem pkey -pubin >"$OUT/ctlog.pub"
: >"$OUT/tsa-chain.pem"
jq -r '(.timestampAuthorities // [])[].certChain.certificates[].rawBytes' "$TR" | while read -r c; do
  printf '%s' "$c" | der2pem x509 >>"$OUT/tsa-chain.pem"; done

OUT_ABS="$(cd "$OUT" && pwd)"
{
  echo "export GITSIGN_FULCIO_ROOT=${OUT_ABS}/fulcio-chain.pem"
  echo "export SIGSTORE_REKOR_PUBLIC_KEY=${OUT_ABS}/rekor.pub"
  echo "export SIGSTORE_CT_LOG_PUBLIC_KEY_FILE=${OUT_ABS}/ctlog.pub"
  [[ -s "$OUT/tsa-chain.pem" ]] && echo "export GITSIGN_TIMESTAMP_CERT_CHAIN=${OUT_ABS}/tsa-chain.pem"
} >"$OUT/gitsign.env"
echo "fulcio certs: $(grep -c 'BEGIN CERTIFICATE' "$OUT/fulcio-chain.pem")  rekor keys: $(grep -c 'BEGIN PUBLIC KEY' "$OUT/rekor.pub")  ct keys: $(grep -c 'BEGIN PUBLIC KEY' "$OUT/ctlog.pub")"
echo "source $OUT/gitsign.env"
