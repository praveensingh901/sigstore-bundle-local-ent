#!/usr/bin/env bash
# =============================================================================
# 04-create-cluster.sh — create the kind cluster wired to the offline mirror.
#
#  1. writes .generated/containerd/certs.d/<registry>/hosts.toml so containerd
#     inside the node pulls docker.io/ghcr.io/quay.io/... images from the
#     local mirror container instead of the internet
#  2. trusts our TLS root for registry.sigstore.local (user images)
#  3. creates the cluster, attaches the mirror to the "kind" docker network
#  4. maps *.sigstore.local -> Traefik ClusterIP in the node's /etc/hosts
#     (re-run scripts/fix-node-dns.sh after a laptop reboot)
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker kind kubectl

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster ${CLUSTER_NAME} already exists"
else
  docker inspect "${MIRROR_NAME}" >/dev/null 2>&1 || die "mirror not running; run 02-load-offline-bundle.sh"

  log "Writing containerd registry configuration"
  CERTS_D="${GEN_DIR}/containerd/certs.d"
  rm -rf "${CERTS_D}"; mkdir -p "${CERTS_D}"
  for reg in ${MIRRORED_REGISTRIES}; do
    server="https://${reg}"; [[ "$reg" == "docker.io" ]] && server="https://registry-1.docker.io"
    mkdir -p "${CERTS_D}/${reg}"
    cat >"${CERTS_D}/${reg}/hosts.toml" <<EOF
# Offline: resolve ${reg} images from the local mirror. override_path makes
# containerd call http://${MIRROR_NAME}:5000/v2/${reg}/<repo>/... exactly as
# 01-build-offline-bundle.sh laid the images out.
server = "${server}"

[host."http://${MIRROR_NAME}:5000/v2/${reg}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
  done
  mkdir -p "${CERTS_D}/${REGISTRY_HOST}"
  cp "$(tls_ca)" "${CERTS_D}/${REGISTRY_HOST}/ca.crt"
  cat >"${CERTS_D}/${REGISTRY_HOST}/hosts.toml" <<EOF
# Private OCI registry (served by Traefik with our wildcard certificate).
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/${REGISTRY_HOST}/ca.crt"
EOF
  chmod -R a+rX "${GEN_DIR}/containerd"

  export GEN_DIR CLUSTER_NAME KIND_NODE_IMAGE_LOCAL
  render "${KIT_ROOT}/config/kind/kind-config.yaml.tpl" "${GEN_DIR}/kind-config.yaml"

  log "Creating kind cluster '${CLUSTER_NAME}' (${KIND_NODE_IMAGE_LOCAL})"
  docker image inspect "${KIND_NODE_IMAGE_LOCAL}" >/dev/null 2>&1 \
    || die "node image ${KIND_NODE_IMAGE_LOCAL} not loaded; run 02-load-offline-bundle.sh"
  kind create cluster --config "${GEN_DIR}/kind-config.yaml" --wait 180s
fi

log "Attaching ${MIRROR_NAME} to the kind network"
docker network connect kind "${MIRROR_NAME}" 2>/dev/null || true

"${KIT_ROOT}/scripts/fix-node-dns.sh"

k wait --for=condition=Ready node --all --timeout=180s >/dev/null
ok "Cluster ready: $(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
k get nodes -o wide
