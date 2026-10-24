#!/usr/bin/env bash
# =============================================================================
# 08-deploy-sigstore.sh — Trillian, Rekor, Fulcio, CT log (Helm), in order:
#
#   trillian  MySQL + log server + log signer      (namespace trillian-system)
#   rekor     transparency log, OUR signer key     (rekor-system)
#   fulcio    code-signing CA, OUR intermediate,   (fulcio-system)
#             trusts Keycloak via CACert
#   ctlog     CT front-end, OUR key; needs Fulcio  (ctlog-system)
#             up first (it fetches Fulcio's root)
#
# Every key is created by 03-generate-pki.sh and handed to the charts as
# Kubernetes Secrets, so redeploying never changes the trust root.
# =============================================================================
# Restore/migration: export REKOR_TREE_ID / CTLOG_TREE_ID to pin existing
# Trillian trees instead of creating new ones (see scripts/restore.sh).
source "$(dirname "$0")/lib.sh"
require_cmd kubectl helm openssl curl jq
load_secrets
HELM_WAIT=(--wait --wait-for-jobs --timeout 15m)
REKOR_TREE_ARGS=(); [[ -n "${REKOR_TREE_ID:-}" ]] && REKOR_TREE_ARGS=(--set-string "server.config.treeID=${REKOR_TREE_ID}")
CTLOG_TREE_ARGS=(); [[ -n "${CTLOG_TREE_ID:-}" ]] && CTLOG_TREE_ARGS=(--set-string "server.config.treeID=${CTLOG_TREE_ID}")

for ns in trillian-system rekor-system fulcio-system ctlog-system; do ensure_ns "$ns"; done
for ns in rekor-system fulcio-system; do ensure_tls_secret "$ns"; done

# ------------------------------------------------------------- secrets -----
log "Creating key Secrets from pki/"
k -n fulcio-system create secret generic fulcio-server-secret \
  --from-file=private="${PKI_DIR}/fulcio/intermediate.key" \
  --from-file=cert="${PKI_DIR}/fulcio/chain.pem" \
  --from-literal=password="${FULCIO_CA_PASSWORD}" \
  --from-literal=public="$(openssl x509 -in "${PKI_DIR}/fulcio/intermediate.crt" -noout -pubkey)" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k -n rekor-system create secret generic rekor-signer \
  --from-file=private="${PKI_DIR}/rekor/rekor.key" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k -n ctlog-system create secret generic ctlog-signer \
  --from-file=private="${PKI_DIR}/ctlog/ctlog.key" \
  --from-literal=password="${CTLOG_KEY_PASSWORD}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
ok "fulcio-server-secret, rekor-signer, ctlog-signer"

# ------------------------------------------------------------- trillian ----
log "Helm: trillian ${CHART_TRILLIAN_VERSION}"
h upgrade --install trillian "$(chart_ref trillian "${CHART_TRILLIAN_VERSION}")" -n trillian-system \
  -f "${KIT_ROOT}/config/helm/trillian-values.yaml" \
  --set-string mysql.auth.password="${MYSQL_PASSWORD}" \
  --set-string mysql.auth.rootPassword="${MYSQL_ROOT_PASSWORD}" \
  "${HELM_WAIT[@]}" >/dev/null
ok "Trillian ready"

# ------------------------------------------------------------- rekor -------
log "Helm: rekor ${CHART_REKOR_VERSION}"
h upgrade --install rekor "$(chart_ref rekor "${CHART_REKOR_VERSION}")" -n rekor-system \
  -f "${KIT_ROOT}/config/helm/rekor-values.yaml" \
  --set-string "server.extraArgs[0]=--rekor_server.signer-passwd=${REKOR_SIGNER_PASSWORD}" \
  "${REKOR_TREE_ARGS[@]}" "${HELM_WAIT[@]}" >/dev/null
ok "Rekor ready (tree $(k -n rekor-system get cm rekor-config -o jsonpath='{.data.treeID}'))"

# ------------------------------------------------------------- fulcio ------
log "Helm: fulcio ${CHART_FULCIO_VERSION}"
TLS_CA_PEM_INDENTED="$(sed 's/^/          /' "$(tls_ca)")"
export TLS_CA_PEM_INDENTED OIDC_ISSUER OIDC_CLIENT_ID OIDC_REALM
render "${KIT_ROOT}/config/helm/fulcio-config-values.yaml.tpl" "${GEN_DIR}/fulcio-config-values.yaml"
h upgrade --install fulcio "$(chart_ref fulcio "${CHART_FULCIO_VERSION}")" -n fulcio-system \
  -f "${KIT_ROOT}/config/helm/fulcio-values.yaml" \
  -f "${GEN_DIR}/fulcio-config-values.yaml" \
  "${HELM_WAIT[@]}" >/dev/null
ok "Fulcio ready"

# ------------------------------------------------------------- ctlog -------
log "Helm: ctlog ${CHART_CTLOG_VERSION}"
h upgrade --install ctlog "$(chart_ref ctlog "${CHART_CTLOG_VERSION}")" -n ctlog-system \
  -f "${KIT_ROOT}/config/helm/ctlog-values.yaml" \
  "${CTLOG_TREE_ARGS[@]}" "${HELM_WAIT[@]}" >/dev/null
wait_rollout ctlog-system deploy/ctlog 300s >/dev/null
ok "CT log ready (tree $(k -n ctlog-system get cm ctlog-config -o jsonpath='{.data.treeID}'))"

# Fulcio started before the CT log existed; restart once so its first
# submission doesn't hit a cold connection.
k -n fulcio-system rollout restart deploy/fulcio-server >/dev/null
wait_rollout fulcio-system deploy/fulcio-server 180s >/dev/null

# ------------------------------------------------------------- verify ------
log "Verifying the deployed services use OUR keys"
C=(curl -fsS --retry 10 --retry-delay 3 --retry-all-errors --cacert "$(tls_ca)")
"${C[@]}" "${FULCIO_URL}/api/v1/rootCert" >"${GEN_DIR}/fulcio-served-chain.pem"
diff <(openssl x509 -in "${GEN_DIR}/fulcio-served-chain.pem" -noout -fingerprint -sha256) \
     <(openssl x509 -in "${PKI_DIR}/fulcio/chain.pem" -noout -fingerprint -sha256) >/dev/null \
  || die "Fulcio serves a different CA than pki/fulcio/chain.pem"
ok "Fulcio CA     = pki/fulcio/chain.pem"
"${C[@]}" "${FULCIO_URL}/api/v2/configuration" | jq -e --arg i "${OIDC_ISSUER}" \
  '.issuers[] | select(.issuerUrl == $i)' >/dev/null \
  || die "Fulcio does not list ${OIDC_ISSUER} (check fulcio logs: kubectl -n fulcio-system logs deploy/fulcio-server)"
ok "Fulcio trusts ${OIDC_ISSUER}"
[[ "$("${C[@]}" "${REKOR_URL}/api/v1/log/publicKey" | pubkey_fp -)" == "$(pubkey_fp "${PKI_DIR}/rekor/rekor.pub")" ]] \
  || die "Rekor signs with a different key than pki/rekor/rekor.pub"
ok "Rekor key     = pki/rekor/rekor.pub"
[[ "$(k -n ctlog-system get secret ctlog-public-key -o jsonpath='{.data.public}' | base64 -d | pubkey_fp -)" \
   == "$(pubkey_fp "${PKI_DIR}/ctlog/ctlog.pub")" ]] || die "CT log key differs from pki/ctlog/ctlog.pub"
ok "CT log key    = pki/ctlog/ctlog.pub"
