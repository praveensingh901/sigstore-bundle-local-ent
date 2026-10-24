#!/usr/bin/env bash
# =============================================================================
# 02-load-offline-bundle.sh — run on the OFFLINE laptop.
#   1. verifies bundle/SHA256SUMS
#   2. docker load host images (kind node, registry:2, TUF builder, demo base)
#   3. starts "sigstore-mirror": registry:2 serving bundle/mirror on
#      127.0.0.1:5000 — kind's containerd pulls every image from it
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker sha256sum curl

[[ -d "${BUNDLE_DIR}/mirror/docker" ]] || die "bundle/mirror is empty — build it online with 01-build-offline-bundle.sh"

if [[ -f "${BUNDLE_DIR}/SHA256SUMS" ]]; then
  log "Verifying bundle integrity"
  ( cd "${BUNDLE_DIR}" && sha256sum --quiet -c SHA256SUMS ) || die "bundle checksum mismatch — re-copy the bundle"
  ok "SHA256SUMS verified"
fi

log "Loading host images"
docker load -i "${BUNDLE_DIR}/images/host-images.tar" | sed 's/^/  /'

log "Starting offline image mirror '${MIRROR_NAME}' on ${MIRROR_ADDR}"
if docker inspect "${MIRROR_NAME}" >/dev/null 2>&1; then
  docker start "${MIRROR_NAME}" >/dev/null
else
  docker run -d --name "${MIRROR_NAME}" --restart unless-stopped \
    -p "${MIRROR_ADDR}:5000" \
    -v "${BUNDLE_DIR}/mirror:/var/lib/registry" \
    "${REGISTRY_IMAGE}" >/dev/null
fi
for _ in $(seq 1 20); do curl -fs "http://${MIRROR_ADDR}/v2/" >/dev/null && break; sleep 1; done
N="$(curl -fs "http://${MIRROR_ADDR}/v2/_catalog?n=1000" | jq '.repositories | length')"
ok "mirror serving ${N} repositories on ${MIRROR_ADDR} (localhost only)"
