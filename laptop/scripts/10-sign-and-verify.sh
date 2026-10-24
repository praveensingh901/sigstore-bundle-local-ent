#!/usr/bin/env bash
# =============================================================================
# 10-sign-and-verify.sh — the complete local keyless workflow.
#
#   1. build   examples/demo-app  -> registry.sigstore.local/demo/hello:v1
#   2. push    to the private registry (TLS, trusted via pki/tls/ca.crt)
#   3. sign    keyless: OIDC token -> Fulcio cert -> Rekor entry -> OCI bundle
#   4. verify  with ONLY the private trusted_root.json
#
# Environment knobs:
#   AUTH=browser   (default) cosign opens the Keycloak login page
#   AUTH=device    device-code flow (headless shells, SSH sessions)
#   AUTH=password  token via scripts/get-token.sh user (automation/tests)
#   AUTH=ci        token via scripts/get-token.sh ci (machine identity)
#   IMAGE_REF=...  skip build/push and sign this existing reference instead
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd cosign crane jq
[[ -f "${OUT_DIR}/trusted_root.json" ]] || die "run 09-configure-cosign.sh first"
# shellcheck disable=SC1091
source "${OUT_DIR}/cosign.env"

AUTH="${AUTH:-browser}"
REPO="${REGISTRY_HOST}/demo/hello"
TAG="${TAG:-v1}"

# ---- 1+2. build and push ---------------------------------------------------
if [[ -z "${IMAGE_REF:-}" ]]; then
  require_cmd docker
  log "Building ${REPO}:${TAG}"
  docker build -q -t "${REPO}:${TAG}" \
    --build-arg BASE_IMAGE="${DEMO_BASE_IMAGE}" "${KIT_ROOT}/examples/demo-app"
  # Push with crane (trusts our CA via SSL_CERT_FILE), so the Docker daemon
  # itself does not need to trust registry.sigstore.local.
  log "Pushing to ${REGISTRY_HOST}"
  mkdir -p "${GEN_DIR}"
  docker save "${REPO}:${TAG}" -o "${GEN_DIR}/demo-image.tar"
  crane push "${GEN_DIR}/demo-image.tar" "${REPO}:${TAG}" >/dev/null
  rm -f "${GEN_DIR}/demo-image.tar"
  IMAGE_REF="${REPO}:${TAG}"
fi

# Always sign the immutable digest, never a mutable tag.
# repo_of: strip "@digest" and/or ":tag" (a ':' in the host:port part is kept).
repo_of() { local r="${1%%@*}" last; last="${r##*/}"; [[ "$last" == *:* ]] && r="${r%:*}"; echo "$r"; }
DIGEST="$(crane digest "${IMAGE_REF}")"
IMAGE_DIGEST="$(repo_of "${IMAGE_REF}")@${DIGEST}"
ok "Artifact: ${IMAGE_DIGEST}"

# ---- 3. sign ------------------------------------------------------------------
SIGN_ARGS=(--yes --signing-config "${SIGSTORE_SIGNING_CONFIG}" --trusted-root "${SIGSTORE_TRUSTED_ROOT}")
case "$AUTH" in
  browser)  SIGN_ARGS+=(--oidc-redirect-url "${SIGSTORE_OIDC_REDIRECT_URL}") ; EXPECT="${DEMO_USER_EMAIL}" ;;
  device)   SIGN_ARGS+=(--fulcio-auth-flow device)                          ; EXPECT="${DEMO_USER_EMAIL}" ;;
  password) SIGN_ARGS+=(--identity-token "$("${KIT_ROOT}/scripts/get-token.sh" user)"); EXPECT="${DEMO_USER_EMAIL}" ;;
  ci)       SIGN_ARGS+=(--identity-token "$("${KIT_ROOT}/scripts/get-token.sh" ci)")  ; EXPECT="ci@${DOMAIN}" ;;
  *) die "AUTH must be browser|device|password|ci" ;;
esac
EXPECT="${EXPECT_IDENTITY:-$EXPECT}"

log "Keyless signing (${AUTH} flow) via ${FULCIO_URL} + ${REKOR_URL}"
cosign sign "${SIGN_ARGS[@]}" "${IMAGE_DIGEST}"
ok "Signed"

# ---- 4. verify ------------------------------------------------------------
log "Verifying with private trust root only"
cosign verify \
  --trusted-root "${SIGSTORE_TRUSTED_ROOT}" \
  --certificate-identity "${EXPECT}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${IMAGE_DIGEST}" >"${OUT_DIR}/last-verify.json"
jq -r '.[] | "  verified : \(.critical.identity."docker-reference")\n  type     : \(.critical.type)"' \
  "${OUT_DIR}/last-verify.json" 2>/dev/null || true
echo "  identity : ${EXPECT}  (issuer ${OIDC_ISSUER})"
ok "Verified ${IMAGE_DIGEST}"

log "Negative test: a wrong identity MUST fail"
if cosign verify --trusted-root "${SIGSTORE_TRUSTED_ROOT}" \
     --certificate-identity "mallory@${DOMAIN}" --certificate-oidc-issuer "${OIDC_ISSUER}" \
     "${IMAGE_DIGEST}" >/dev/null 2>&1; then
  die "verification unexpectedly succeeded for the wrong identity"
fi
ok "Wrong identity rejected (as expected)"
echo "${IMAGE_DIGEST}" >"${OUT_DIR}/last-signed-image"
echo "  next: scripts/11-inspect-rekor.sh"
