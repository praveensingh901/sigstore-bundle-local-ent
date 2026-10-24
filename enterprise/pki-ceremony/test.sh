#!/usr/bin/env bash
# enterprise/pki-ceremony/test.sh — tests kms-csr and the two verify scripts
# with file keys and a throwaway root (no AWS). Positive path for both
# profiles, then the failures the scripts must catch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; cd "$W"
( cd "$HERE/kms-csr" && go build -o "$W/kms-csr" . )
CNF="$HERE/openssl-profiles.cnf"
gen() { openssl genpkey -algorithm EC -pkeyopt "ec_paramgen_curve:$2" -out "$1.key" 2>/dev/null; openssl pkey -in "$1.key" -pubout -out "$1.pub"; }
expect_fail() { if "$@" >/dev/null 2>&1; then echo "FAIL: expected failure: $*"; exit 1; fi; echo "ok   rejected: ${*: -3}"; }

gen root P-384
openssl req -x509 -new -key root.key -subj "/CN=Test Root/O=Example Bank/C=AE" -days 30 -sha384 -out root.crt \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
gen fulcio-ca P-384; gen tsa P-384; gen weak P-256

./kms-csr --key-file fulcio-ca.key --profile fulcio-ca --subject "CN=Test Code-Signing CA,O=Example Bank,C=AE" --out fulcio-ca.csr
./kms-csr --key-file tsa.key --profile tsa --subject "CN=Test Timestamping,O=Example Bank,C=AE" --out tsa.csr
"$HERE/verify-csr.sh" fulcio-ca.csr fulcio-ca fulcio-ca.pub
"$HERE/verify-csr.sh" tsa.csr tsa tsa.pub

sign() { openssl x509 -req -in "$1.csr" -CA root.crt -CAkey root.key -CAcreateserial -days 10 -sha384 \
           -extfile "$CNF" -extensions "$2" -out "$1.crt" 2>/dev/null; }
sign fulcio-ca sigstore_ca; sign tsa sigstore_tsa
"$HERE/verify-issued-cert.sh" fulcio-ca fulcio-ca.crt root.crt fulcio-ca.pub
"$HERE/verify-issued-cert.sh" tsa tsa.crt root.crt tsa.pub

# negatives
expect_fail "$HERE/verify-csr.sh" fulcio-ca.csr fulcio-ca tsa.pub                    # key mismatch
expect_fail "$HERE/verify-csr.sh" tsa.csr fulcio-ca                                  # wrong profile
./kms-csr --key-file weak.key --profile fulcio-ca --subject "CN=weak" --out weak.csr
expect_fail "$HERE/verify-csr.sh" weak.csr fulcio-ca                                 # P-256
printf '[bad]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > bad.cnf
openssl x509 -req -in fulcio-ca.csr -CA root.crt -CAkey root.key -CAcreateserial -days 10 -sha384 -extfile bad.cnf -extensions bad -out noeku.crt 2>/dev/null
expect_fail "$HERE/verify-issued-cert.sh" fulcio-ca noeku.crt root.crt              # no codeSigning EKU
printf '[bad]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=timeStamping\n' > bad.cnf
openssl x509 -req -in tsa.csr -CA root.crt -CAkey root.key -CAcreateserial -days 10 -sha384 -extfile bad.cnf -extensions bad -out tsanc.crt 2>/dev/null
expect_fail "$HERE/verify-issued-cert.sh" tsa tsanc.crt root.crt                    # EKU not critical
openssl req -x509 -new -key root.key -subj "/CN=EKU Root" -days 30 -sha384 -out ekuroot.crt \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "extendedKeyUsage=serverAuth"
openssl x509 -req -in fulcio-ca.csr -CA ekuroot.crt -CAkey root.key -CAcreateserial -days 10 -sha384 -extfile "$CNF" -extensions sigstore_ca -out f2.crt 2>/dev/null
expect_fail "$HERE/verify-issued-cert.sh" fulcio-ca f2.crt ekuroot.crt              # root EKU excludes codeSigning
echo "PASS ceremony tools"
