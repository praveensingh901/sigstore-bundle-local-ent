#!/usr/bin/env bash
# verify-csr.sh <csr.pem> <fulcio-ca|tsa> [kms-uri|public-key.pem]
# Checks a ceremony CSR before it goes to the offline root:
#   * self-signature verifies
#   * requested extensions match the profile
#   * (optional) the public key equals the KMS key / given PEM key
set -euo pipefail
CSR="${1:?csr}"; PROFILE="${2:?fulcio-ca|tsa}"; KEYREF="${3:-}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

openssl req -in "$CSR" -noout -verify 2>&1 | grep -q "verify OK" || fail "CSR self-signature"
pass "self-signature"
TXT="$(openssl req -in "$CSR" -noout -text)"
grep -q "NIST CURVE: P-384" <<<"$TXT" || fail "public key must be ECDSA P-384"
pass "ECDSA P-384 key"
case "$PROFILE" in
  fulcio-ca)
    grep -A1 "Basic Constraints: critical" <<<"$TXT" | grep -q "CA:TRUE, pathlen:0" || fail "basicConstraints must be critical CA:TRUE, pathlen:0"
    grep -A1 "Key Usage: critical" <<<"$TXT" | grep -q "Certificate Sign, CRL Sign" || fail "keyUsage must be critical keyCertSign, cRLSign"
    grep -A1 "Extended Key Usage" <<<"$TXT" | grep -q "Code Signing" || fail "EKU codeSigning missing"
    ;;
  tsa)
    grep -A1 "Basic Constraints: critical" <<<"$TXT" | grep -q "CA:FALSE" || fail "basicConstraints must be critical CA:FALSE"
    grep -A1 "Key Usage: critical" <<<"$TXT" | grep -q "Digital Signature" || fail "keyUsage must be critical digitalSignature"
    grep -A1 "Extended Key Usage: critical" <<<"$TXT" | grep -qx "\s*Time Stamping" || fail "EKU must be critical and only timeStamping"
    ;;
  *) fail "profile must be fulcio-ca or tsa" ;;
esac
pass "requested extensions match profile $PROFILE"

if [[ -n "$KEYREF" ]]; then
  CSR_FP="$(openssl req -in "$CSR" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
  if [[ "$KEYREF" == awskms://* ]]; then
    KEYID="${KEYREF#awskms://}"; KEYID="${KEYID#*/}"
    KMS_FP="$(aws kms get-public-key --key-id "$KEYID" --query PublicKey --output text | base64 -d | sha256sum | cut -d' ' -f1)"
  else
    KMS_FP="$(openssl pkey -pubin -in "$KEYREF" -outform DER | sha256sum | cut -d' ' -f1)"
  fi
  [[ "$CSR_FP" == "$KMS_FP" ]] || fail "CSR public key does not match $KEYREF"
  pass "public key matches $KEYREF"
fi
echo "PASS $CSR"
