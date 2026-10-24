#!/usr/bin/env bash
# =============================================================================
# 03-generate-pki.sh — create ALL keys, certificates and passwords locally.
#
#   pki/
#   ├── secrets.env                   random passwords (chmod 600)
#   ├── meta.env                      trust start time used by trusted_root.json
#   ├── tls/      ca.key ca.crt       local TLS root CA (trust this on the laptop)
#   │             wildcard.key/.crt   *.sigstore.local server cert (+ fullchain)
#   ├── fulcio/   root.key root.crt   OFFLINE code-signing root (encrypted key)
#   │             intermediate.key    issuing CA used by Fulcio (encrypted key)
#   │             intermediate.crt
#   │             chain.pem           intermediate + root (what Fulcio loads)
#   ├── rekor/    rekor.key rekor.pub transparency-log signing key (encrypted)
#   └── ctlog/    ctlog.key ctlog.pub CT log signing key (legacy-encrypted PEM)
#
# Idempotent: existing material is kept. Use --force to regenerate everything
# (this INVALIDATES every signature made with the old trust root).
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd openssl

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1
if [[ -f "${PKI_DIR}/fulcio/chain.pem" && $FORCE -eq 0 ]]; then
  ok "PKI already exists in ${PKI_DIR} (use --force to regenerate)"; exit 0
fi
if [[ $FORCE -eq 1 ]]; then
  warn "Regenerating PKI: all previous signatures will stop verifying."
  rm -rf "${PKI_DIR}"
fi

umask 077
mkdir -p "${PKI_DIR}"/{tls,fulcio,rekor,ctlog}
EXT="${KIT_ROOT}/config/pki/extensions.cnf"
export DOMAIN KEYCLOAK_HOST FULCIO_HOST REKOR_HOST REGISTRY_HOST TUF_HOST

rand() { openssl rand -hex 24; }

log "Generating passwords -> pki/secrets.env"
cat >"${SECRETS_FILE}" <<EOF
# Generated $(date -u +%FT%TZ). Treat like a private key. Back it up with pki/.
FULCIO_ROOT_PASSWORD=$(rand)
FULCIO_CA_PASSWORD=$(rand)
REKOR_SIGNER_PASSWORD=$(rand)
CTLOG_KEY_PASSWORD=$(rand)
KEYCLOAK_ADMIN_PASSWORD=$(rand)
DEMO_USER_PASSWORD=$(rand)
CI_CLIENT_SECRET=$(rand)
MYSQL_ROOT_PASSWORD=$(rand)
MYSQL_PASSWORD=$(rand)
EOF
load_secrets

# Trust material becomes valid from "now minus 5 minutes" to tolerate clock skew.
TRUST_START_TIME="$(date -u -d '-5 minutes' +%FT%TZ 2>/dev/null || date -u -v-5M +%FT%TZ)"
echo "TRUST_START_TIME=${TRUST_START_TIME}" >"${PKI_DIR}/meta.env"

# ---------------------------------------------------------------- TLS ------
log "TLS root CA (EC P-256, 10y)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${PKI_DIR}/tls/ca.key"
openssl req -x509 -new -key "${PKI_DIR}/tls/ca.key" -sha256 -days 3650 \
  -subj "/O=Sigstore Offline Lab/OU=TLS/CN=Sigstore Offline TLS Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "${PKI_DIR}/tls/ca.crt"

log "Wildcard server certificate *.${DOMAIN} (397 days, browser-compliant)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${PKI_DIR}/tls/wildcard.key"
openssl req -new -key "${PKI_DIR}/tls/wildcard.key" \
  -subj "/O=Sigstore Offline Lab/CN=*.${DOMAIN}" -out "${PKI_DIR}/tls/wildcard.csr"
openssl x509 -req -in "${PKI_DIR}/tls/wildcard.csr" -sha256 -days 397 \
  -CA "${PKI_DIR}/tls/ca.crt" -CAkey "${PKI_DIR}/tls/ca.key" -CAcreateserial \
  -extfile "$EXT" -extensions tls_server -out "${PKI_DIR}/tls/wildcard.crt"
cat "${PKI_DIR}/tls/wildcard.crt" "${PKI_DIR}/tls/ca.crt" >"${PKI_DIR}/tls/wildcard-fullchain.crt"
rm -f "${PKI_DIR}/tls/wildcard.csr"

# ------------------------------------------------------------- Fulcio ------
log "Fulcio ROOT CA (EC P-384, 10y, encrypted key — keep offline)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -aes-256-cbc -pass env:FULCIO_ROOT_PASSWORD -out "${PKI_DIR}/fulcio/root.key"
openssl req -x509 -new -key "${PKI_DIR}/fulcio/root.key" -passin env:FULCIO_ROOT_PASSWORD \
  -sha384 -days 3650 \
  -subj "/O=Sigstore Offline Lab/OU=Code Signing/CN=Sigstore Offline Fulcio Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "${PKI_DIR}/fulcio/root.crt"

log "Fulcio INTERMEDIATE (issuing) CA (EC P-384, 5y, EKU codeSigning)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -aes-256-cbc -pass env:FULCIO_CA_PASSWORD -out "${PKI_DIR}/fulcio/intermediate.key"
openssl req -new -key "${PKI_DIR}/fulcio/intermediate.key" -passin env:FULCIO_CA_PASSWORD \
  -subj "/O=Sigstore Offline Lab/OU=Code Signing/CN=Sigstore Offline Fulcio Intermediate CA" \
  -out "${PKI_DIR}/fulcio/intermediate.csr"
openssl x509 -req -in "${PKI_DIR}/fulcio/intermediate.csr" -sha384 -days 1825 \
  -CA "${PKI_DIR}/fulcio/root.crt" -CAkey "${PKI_DIR}/fulcio/root.key" \
  -passin env:FULCIO_ROOT_PASSWORD -CAcreateserial \
  -extfile "$EXT" -extensions fulcio_intermediate -out "${PKI_DIR}/fulcio/intermediate.crt"
rm -f "${PKI_DIR}/fulcio/intermediate.csr"
# Order matters: issuing cert first, root last (Fulcio + cosign both expect it).
cat "${PKI_DIR}/fulcio/intermediate.crt" "${PKI_DIR}/fulcio/root.crt" >"${PKI_DIR}/fulcio/chain.pem"

# -------------------------------------------------------------- Rekor ------
log "Rekor signer key (EC P-256, PKCS#8 encrypted)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  -aes-256-cbc -pass env:REKOR_SIGNER_PASSWORD -out "${PKI_DIR}/rekor/rekor.key"
openssl pkey -in "${PKI_DIR}/rekor/rekor.key" -passin env:REKOR_SIGNER_PASSWORD \
  -pubout -out "${PKI_DIR}/rekor/rekor.pub"

# -------------------------------------------------------------- CTLog ------
# The CT front-end (trillian ctfe) only decrypts legacy "Proc-Type: 4,ENCRYPTED"
# PEM, so this key is written in traditional (SEC1) format.
log "CT log signer key (EC P-256, legacy-encrypted PEM)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  | openssl ec -aes256 -passout env:CTLOG_KEY_PASSWORD -out "${PKI_DIR}/ctlog/ctlog.key" 2>/dev/null
grep -q "Proc-Type: 4,ENCRYPTED" "${PKI_DIR}/ctlog/ctlog.key" \
  || die "CT key is not in legacy encrypted format (OpenSSL too new? see Troubleshooting §PKI)"
openssl ec -in "${PKI_DIR}/ctlog/ctlog.key" -passin env:CTLOG_KEY_PASSWORD \
  -pubout -out "${PKI_DIR}/ctlog/ctlog.pub" 2>/dev/null

chmod 600 "${PKI_DIR}"/*/*.key "${SECRETS_FILE}"
chmod 644 "${PKI_DIR}"/*/*.crt "${PKI_DIR}"/*/*.pub "${PKI_DIR}/fulcio/chain.pem"

# -------------------------------------------------------------- Verify -----
log "Verifying chains"
openssl verify -CAfile "${PKI_DIR}/tls/ca.crt" "${PKI_DIR}/tls/wildcard.crt" >/dev/null
openssl verify -CAfile "${PKI_DIR}/fulcio/root.crt" "${PKI_DIR}/fulcio/intermediate.crt" >/dev/null
openssl x509 -in "${PKI_DIR}/fulcio/intermediate.crt" -noout -ext extendedKeyUsage | grep -q "Code Signing" \
  || die "intermediate is missing EKU codeSigning"
ok "PKI written to ${PKI_DIR}"
echo
openssl x509 -in "${PKI_DIR}/fulcio/root.crt" -noout -subject -fingerprint -sha256
openssl x509 -in "${PKI_DIR}/fulcio/intermediate.crt" -noout -subject -fingerprint -sha256
warn "Copy ${PKI_DIR} to encrypted offline storage now (see docs/06-disaster-recovery.md)."
