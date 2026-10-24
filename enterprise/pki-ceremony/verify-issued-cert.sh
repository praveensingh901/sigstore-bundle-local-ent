#!/usr/bin/env bash
# verify-issued-cert.sh <fulcio-ca|tsa> <issued.crt> <root.crt> [kms-uri|public-key.pem]
# Checks the certificate the offline root issued before anything uses it.
# Exit code 0 only if every check passes.
set -euo pipefail
PROFILE="${1:?fulcio-ca|tsa}"; CRT="${2:?issued cert}"; ROOT="${3:?root cert}"; KEYREF="${4:-}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

openssl verify -x509_strict -CAfile "$ROOT" "$CRT" >/dev/null 2>&1 || fail "does not chain to $ROOT"
pass "chains to $(openssl x509 -in "$ROOT" -noout -subject | sed 's/^subject=//')"
openssl x509 -in "$CRT" -noout -checkend 0 >/dev/null || fail "certificate already expired"
END="$(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)"
# GNU date (Linux) or BSD date (macOS ceremony laptops)
END_S="$(date -d "$END" +%s 2>/dev/null || date -j -f "%b %e %T %Y %Z" "$END" +%s)"
DAYS=$(( (END_S - $(date +%s)) / 86400 ))
pass "valid, ${DAYS} days left"

# Key algorithm: both profiles use ECDSA P-384 (KMS ECC_NIST_P384).
openssl x509 -in "$CRT" -noout -text | grep -q "NIST CURVE: P-384" || fail "public key must be ECDSA P-384"
pass "ECDSA P-384 key"

# Go's x509.Verify (used by Fulcio and the TSA at start-up) applies the
# requested EKU to every certificate in the chain, the root included. A root
# with an EKU extension must therefore also allow the purpose (or anyEKU).
NEED_EKU="Code Signing"; [[ "$PROFILE" == tsa ]] && NEED_EKU="Time Stamping"
ROOT_TXT="$(openssl x509 -in "$ROOT" -noout -text)"
if grep -q "X509v3 Extended Key Usage" <<<"$ROOT_TXT"; then
  grep -A1 "X509v3 Extended Key Usage" <<<"$ROOT_TXT" | grep -Eq "$NEED_EKU|Any Extended Key Usage" \
    || fail "root has an EKU extension without $NEED_EKU: Fulcio/TSA chain verification will fail"
  pass "root EKU allows $NEED_EKU"
else
  pass "root has no EKU extension (no restriction)"
fi

TXT="$(openssl x509 -in "$CRT" -noout -text)"
case "$PROFILE" in
  fulcio-ca)
    grep -A1 "Basic Constraints: critical" <<<"$TXT" | grep -q "CA:TRUE, pathlen:0" || fail "basicConstraints must be critical CA:TRUE, pathlen:0"
    grep -A1 "Key Usage: critical" <<<"$TXT" | grep -q "Certificate Sign, CRL Sign" || fail "keyUsage must include keyCertSign, cRLSign (critical)"
    grep -A1 "Extended Key Usage" <<<"$TXT" | grep -q "Code Signing" || fail "EKU codeSigning missing: Fulcio will refuse to start"
    ;;
  tsa)
    grep -A1 "Basic Constraints: critical" <<<"$TXT" | grep -q "CA:FALSE" || fail "basicConstraints must be critical CA:FALSE"
    grep -A1 "Key Usage: critical" <<<"$TXT" | grep -q "Digital Signature" || fail "keyUsage must be critical digitalSignature"
    grep -A1 "Extended Key Usage: critical" <<<"$TXT" | grep -qx "\s*Time Stamping" || fail "EKU must be critical and only timeStamping (RFC 3161)"
    ;;
  *) fail "profile must be fulcio-ca or tsa" ;;
esac
pass "extensions match profile $PROFILE"
grep -q "Subject Key Identifier" <<<"$TXT" || fail "subjectKeyIdentifier missing"
grep -q "Authority Key Identifier" <<<"$TXT" || fail "authorityKeyIdentifier missing"
pass "key identifiers present"

if [[ -n "$KEYREF" ]]; then
  CRT_FP="$(openssl x509 -in "$CRT" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
  if [[ "$KEYREF" == awskms://* ]]; then
    KEYID="${KEYREF#awskms://}"; KEYID="${KEYID#*/}"
    KMS_FP="$(aws kms get-public-key --key-id "$KEYID" --query PublicKey --output text | base64 -d | sha256sum | cut -d' ' -f1)"
  else
    KMS_FP="$(openssl pkey -pubin -in "$KEYREF" -outform DER | sha256sum | cut -d' ' -f1)"
  fi
  [[ "$CRT_FP" == "$KMS_FP" ]] || fail "certificate public key is not the KMS key $KEYREF"
  pass "public key matches $KEYREF"
fi
echo "PASS $CRT"
