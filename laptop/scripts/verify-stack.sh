#!/usr/bin/env bash
# =============================================================================
# verify-stack.sh — one-shot health report for every component.
# Exit code 0 only when every check passes. Safe to run any time.
# =============================================================================
source "$(dirname "$0")/lib.sh"
trap - ERR; set +e
PASS=0; FAILS=0
row() { if [[ "$2" == ok ]]; then printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "$3"; PASS=$((PASS+1));
        else printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "$3"; FAILS=$((FAILS+1)); fi; }
t() { local name="$1" hint="$2"; shift 2; local out; if out="$("$@" 2>&1)"; then row "$name" ok "${out:0:60}"; else row "$name" fail "$hint"; fi; }
C=(curl -fsS -m 10 --cacert "$(tls_ca)")

echo "== Platform"
t "mirror container"            "docker start ${MIRROR_NAME}"        docker inspect -f '{{.State.Status}}' "${MIRROR_NAME}"
t "kind cluster"                "scripts/04-create-cluster.sh"       bash -c "kind get clusters | grep -x ${CLUSTER_NAME}"
t "node Ready"                  "kubectl describe node"              bash -c "kubectl --context $(kctx) get nodes --no-headers | awk '{print \$2}' | grep -x Ready"
t "node /etc/hosts entry"       "scripts/fix-node-dns.sh (after reboot)" docker exec "${CLUSTER_NAME}-control-plane" grep -c sigstore-offline /etc/hosts
for hn in ${ALL_HOSTS}; do
  t "laptop DNS ${hn}"          "scripts/setup-hosts.sh"             bash -c "getent hosts ${hn} | grep -q 127.0.0.1 && echo 127.0.0.1"
done

echo "== Pods"
for ns in traefik registry keycloak trillian-system rekor-system fulcio-system ctlog-system tuf-system kyverno; do
  if k get ns "$ns" >/dev/null 2>&1; then
    bad="$(k -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1"("$3")"}' | tr '\n' ' ')"
    [[ -z "$bad" ]] && row "namespace $ns" ok "all pods Running/Completed" || row "namespace $ns" fail "$bad"
  else
    row "namespace $ns" fail "not deployed"
  fi
done

echo "== Endpoints (TLS verified against pki/tls/ca.crt)"
t "Keycloak discovery"          "kubectl -n keycloak logs deploy/keycloak" \
  bash -c "${C[*]} ${OIDC_ISSUER}/.well-known/openid-configuration | jq -er '.issuer' | grep -x '${OIDC_ISSUER}'"
t "Fulcio CA = pki chain"       "08-deploy-sigstore.sh" \
  bash -c "diff <(${C[*]} ${FULCIO_URL}/api/v1/rootCert | openssl x509 -noout -fingerprint -sha256) <(openssl x509 -in ${PKI_DIR}/fulcio/chain.pem -noout -fingerprint -sha256) && echo match"
t "Fulcio trusts Keycloak"      "fulcio logs: issuer discovery" \
  bash -c "${C[*]} ${FULCIO_URL}/api/v2/configuration | jq -er '.issuers[].issuerUrl' | grep -x '${OIDC_ISSUER}'"
t "Rekor key = pki rekor.pub"   "rekor-signer secret" \
  bash -c "source ${KIT_ROOT}/scripts/lib.sh; [[ \$(${C[*]} ${REKOR_URL}/api/v1/log/publicKey | pubkey_fp) == \$(pubkey_fp ${PKI_DIR}/rekor/rekor.pub) ]] && echo match"
t "Rekor log"                   "trillian-logserver" \
  bash -c "${C[*]} ${REKOR_URL}/api/v1/log | jq -r '\"treeSize=\(.treeSize)\"'"
t "CT log key = pki ctlog.pub"  "ctlog-signer secret" \
  bash -c "source ${KIT_ROOT}/scripts/lib.sh; [[ \$(kubectl --context $(kctx) -n ctlog-system get secret ctlog-public-key -o jsonpath='{.data.public}' | base64 -d | pubkey_fp) == \$(pubkey_fp ${PKI_DIR}/ctlog/ctlog.pub) ]] && echo match"
t "Registry API"                "06-deploy-registry.sh" \
  bash -c "${C[*]} -o /dev/null -w '%{http_code}' https://${REGISTRY_HOST}/v2/ | grep -x 200"
t "TUF mirror"                  "12-publish-tuf.sh" \
  bash -c "${C[*]} ${TUF_URL}/timestamp.json | jq -er '.signed.expires'"

echo "== Client trust"
t "trusted_root.json"           "09-configure-cosign.sh"   jq -er '.mediaType' "${OUT_DIR}/trusted_root.json"
t "signing_config.json"         "09-configure-cosign.sh"   jq -er '.mediaType' "${OUT_DIR}/signing_config.json"
if [[ -f "${OUT_DIR}/tuf/meta.env" ]]; then
  # shellcheck disable=SC1091
  source "${OUT_DIR}/tuf/meta.env"
  exp_s="$(date -d "${TUF_EXPIRES}" +%s 2>/dev/null || echo 0)"; days=$(( (exp_s - $(date +%s)) / 86400 ))
  (( days > 30 )) && row "TUF metadata expiry" ok "${days} days left" || row "TUF metadata expiry" fail "${days} days left — re-run 12-publish-tuf.sh"
fi
t "Kyverno policy ready"        "13-deploy-policy.sh" \
  bash -c "kubectl --context $(kctx) get imagevalidatingpolicy require-private-sigstore-signature -o jsonpath='{.status.conditionStatus.ready}' | grep -x true"

echo
echo "  ${PASS} passed, ${FAILS} failed"
exit $(( FAILS > 0 ))
