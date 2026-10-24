#!/usr/bin/env bash
# =============================================================================
# 05-deploy-ingress.sh — Traefik (TLS termination) + in-cluster DNS for
# *.sigstore.local.
#
#   * Traefik Service gets the FIXED ClusterIP ${INGRESS_CLUSTER_IP}
#   * CoreDNS gets an extra server block answering *.sigstore.local with it
#   * prints the hosts-file line the laptop needs (scripts/setup-hosts.sh)
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd kubectl helm

log "Installing Traefik ${CHART_TRAEFIK_VERSION}"
ensure_tls_secret traefik
h upgrade --install traefik "$(chart_ref traefik "${CHART_TRAEFIK_VERSION}")" \
  -n traefik --create-namespace \
  -f "${KIT_ROOT}/config/helm/traefik-values.yaml" \
  --set service.spec.clusterIP="${INGRESS_CLUSTER_IP}" \
  --wait --timeout 5m >/dev/null
ok "Traefik ready at ClusterIP ${INGRESS_CLUSTER_IP} (host ports 80/443)"

log "Adding *.${DOMAIN} zone to CoreDNS"
export DOMAIN INGRESS_CLUSTER_IP
render "${KIT_ROOT}/config/coredns/sigstore-zone.Corefile.tpl" "${GEN_DIR}/sigstore-zone.Corefile"
CURRENT="$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
# Remove any previous copy of our block (idempotent), then append.
CLEAN="$(printf '%s\n' "$CURRENT" | awk -v d="${DOMAIN}:53 {" '
  $0==d {skip=1; depth=0}
  skip { n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if (depth<=0 && m>0) {skip=0}; next }
  {print}')"
printf '%s\n%s\n' "$CLEAN" "$(cat "${GEN_DIR}/sigstore-zone.Corefile")" >"${GEN_DIR}/Corefile"
k -n kube-system create configmap coredns --from-file=Corefile="${GEN_DIR}/Corefile" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k -n kube-system rollout restart deployment/coredns >/dev/null
wait_rollout kube-system deployment/coredns 120s >/dev/null

log "Checking in-cluster resolution"
k run dnscheck-$$ --rm -i --restart=Never --quiet \
  --image="docker.io/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e" \
  -- nslookup "${FULCIO_HOST}" 2>/dev/null | grep -q "${INGRESS_CLUSTER_IP}" \
  && ok "pods resolve ${FULCIO_HOST} -> ${INGRESS_CLUSTER_IP}" \
  || warn "pod DNS check inconclusive (see docs/08 §DNS)"

echo
echo "  Laptop hosts file must contain:"
echo "    127.0.0.1 ${ALL_HOSTS}"
echo "  Linux/WSL:  sudo scripts/setup-hosts.sh"
echo "  Windows:    windows\\Setup-Hosts.ps1 (Administrator PowerShell)"
