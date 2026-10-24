#!/usr/bin/env bash
# =============================================================================
# 13-deploy-policy.sh — enforce signature verification at admission (Kyverno).
#
#   scripts/13-deploy-policy.sh                 install Kyverno + policy (Deny) + test
#   POLICY_ACTION=Audit scripts/13-deploy-policy.sh   report-only mode
#   scripts/13-deploy-policy.sh --render-only   just write .generated/kyverno-verify-images.yaml
#
# Kyverno trusts our TLS root (global.caCertificates) so it can talk to
# registry.sigstore.local and tuf.sigstore.local, and bootstraps Sigstore trust
# from the private TUF mirror published by 12-publish-tuf.sh.
# =============================================================================
source "$(dirname "$0")/lib.sh"
[[ -f "${OUT_DIR}/tuf/root.json" ]] || die "run 12-publish-tuf.sh first"

export POLICY_ACTION="${POLICY_ACTION:-Deny}"
export DOMAIN_REGEX="${DOMAIN//./\\.}"
TUF_ROOT_B64="$(base64 -w0 "${OUT_DIR}/tuf/root.json" 2>/dev/null || base64 <"${OUT_DIR}/tuf/root.json" | tr -d '\n')"
export TUF_ROOT_B64
render "${KIT_ROOT}/config/policies/kyverno/verify-images.yaml.tpl" "${GEN_DIR}/kyverno-verify-images.yaml"
ok "Rendered ${GEN_DIR}/kyverno-verify-images.yaml (action=${POLICY_ACTION})"
[[ "${1:-}" == "--render-only" ]] && exit 0

require_cmd kubectl helm
log "Installing Kyverno ${CHART_KYVERNO_VERSION}"
h upgrade --install kyverno "$(chart_ref kyverno "${CHART_KYVERNO_VERSION}")" \
  -n kyverno --create-namespace \
  -f "${KIT_ROOT}/config/helm/kyverno-values.yaml" \
  --set-file global.caCertificates.data="$(tls_ca)" \
  --wait --timeout 10m >/dev/null
ok "Kyverno ready"

log "Applying ImageValidatingPolicy"
# CRDs can take a moment to be served after a fresh install.
for _ in $(seq 1 30); do k apply -f "${GEN_DIR}/kyverno-verify-images.yaml" >/dev/null 2>&1 && break; sleep 4; done
k get imagevalidatingpolicy require-private-sigstore-signature >/dev/null
for _ in $(seq 1 30); do
  [[ "$(k get imagevalidatingpolicy require-private-sigstore-signature -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" == "true" ]] && break
  sleep 4
done
ok "Policy active"

[[ "${POLICY_ACTION}" == "Deny" ]] || exit 0
[[ -f "${OUT_DIR}/last-signed-image" ]] || { warn "no signed image yet; run 10-sign-and-verify.sh then re-run this script to test"; exit 0; }
SIGNED="$(cat "${OUT_DIR}/last-signed-image")"
ensure_ns demo
log "Admission test 1: signed image must be ADMITTED"
k -n demo run signed --image="${SIGNED}" --restart=Never --dry-run=server -o name \
  || die "signed image was rejected (see docs/08 §Kyverno)"
ok "signed image admitted"

log "Admission test 2: unsigned image must be DENIED"
UNSIGNED="${REGISTRY_HOST}/demo/unsigned:v1"
if command -v crane >/dev/null; then
  SSL_CERT_FILE="${OUT_DIR}/ca-bundle.pem" crane copy "${SIGNED}" "${UNSIGNED}" >/dev/null 2>&1 || true
fi
if k -n demo run unsigned --image="${UNSIGNED}" --restart=Never --dry-run=server -o name 2>"${GEN_DIR}/deny.txt"; then
  die "unsigned image was admitted — policy not enforcing"
fi
sed 's/^/    /' "${GEN_DIR}/deny.txt" | head -5
ok "unsigned image denied"
