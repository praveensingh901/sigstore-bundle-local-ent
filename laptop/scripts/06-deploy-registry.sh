#!/usr/bin/env bash
# =============================================================================
# 06-deploy-registry.sh — private OCI registry at https://registry.sigstore.local
# Images AND their cosign signatures/attestations (OCI referrers) live here.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

ensure_tls_secret registry
export REGISTRY_IMAGE REGISTRY_HOST
render "${KIT_ROOT}/config/registry/registry.yaml.tpl" "${GEN_DIR}/registry.yaml"
k apply -f "${GEN_DIR}/registry.yaml" >/dev/null
wait_rollout registry deploy/registry 180s >/dev/null
ok "registry pod ready"

log "Checking https://${REGISTRY_HOST}/v2/ from the laptop"
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$(tls_ca)" "https://${REGISTRY_HOST}/v2/" || true)"
  [[ "$code" == "200" ]] && break; sleep 3
done
[[ "$code" == "200" ]] || die "registry not reachable over TLS (got HTTP ${code}); is the hosts file set? (scripts/setup-hosts.sh)"
ok "https://${REGISTRY_HOST} serving (OCI distribution API v2)"
