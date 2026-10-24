# shellcheck shell=bash
# =============================================================================
# sigstore-offline :: central configuration
# -----------------------------------------------------------------------------
# Every script sources this file (via scripts/lib.sh). Change values here, not
# inside individual scripts. Anything marked "pinned" was verified together;
# change it only if you also re-run 01-build-offline-bundle.sh while online.
# =============================================================================

# ---- Naming / DNS -----------------------------------------------------------
# All public endpoints live under this private DNS zone. ".local" names never
# leave the laptop: the hosts file (laptop) and CoreDNS (cluster) resolve them.
export DOMAIN="${DOMAIN:-sigstore.local}"
export CLUSTER_NAME="${CLUSTER_NAME:-sigstore}"

export KEYCLOAK_HOST="keycloak.${DOMAIN}"
export FULCIO_HOST="fulcio.${DOMAIN}"
export REKOR_HOST="rekor.${DOMAIN}"
export REGISTRY_HOST="registry.${DOMAIN}"
export TUF_HOST="tuf.${DOMAIN}"
export ALL_HOSTS="${KEYCLOAK_HOST} ${FULCIO_HOST} ${REKOR_HOST} ${REGISTRY_HOST} ${TUF_HOST}"

# Fixed ClusterIP for the Traefik ingress Service. Pods (via CoreDNS) and the
# kind node's containerd (via /etc/hosts) resolve every *.${DOMAIN} name to it.
# Must sit inside kind's default service CIDR 10.96.0.0/16.
export INGRESS_CLUSTER_IP="${INGRESS_CLUSTER_IP:-10.96.100.100}"

# ---- OIDC (Keycloak) ---------------------------------------------------------
export OIDC_REALM="sigstore"
export OIDC_CLIENT_ID="sigstore"                 # public client used by cosign
export OIDC_CI_CLIENT_ID="sigstore-ci"           # confidential client for CI
export OIDC_ISSUER="https://${KEYCLOAK_HOST}/realms/${OIDC_REALM}"
export OIDC_REDIRECT_URL="http://localhost:8765/auth/callback"
export DEMO_USER="alice"
export DEMO_USER_EMAIL="alice@${DOMAIN}"

# ---- Sigstore service URLs (as seen by cosign on the laptop) ---------------
export FULCIO_URL="https://${FULCIO_HOST}"
export REKOR_URL="https://${REKOR_HOST}"
export TUF_URL="https://${TUF_HOST}"                 # private TUF mirror (trust distribution)
export CTLOG_PREFIX="sigstore"                   # CT log path: /<prefix>
export SIGSTORE_OPERATOR="${DOMAIN}"             # free-text operator label

# ---- Offline image mirror (plain HTTP, laptop-local plumbing only) ---------
export MIRROR_NAME="sigstore-mirror"
export MIRROR_PORT="5000"                        # bound to 127.0.0.1 only
export MIRROR_ADDR="127.0.0.1:${MIRROR_PORT}"
# Upstream registries whose images are mirrored. containerd in kind is told to
# fetch <registry>/<repo> from http://sigstore-mirror:5000/v2/<registry>/<repo>.
export MIRRORED_REGISTRIES="docker.io ghcr.io quay.io gcr.io registry.k8s.io reg.kyverno.io"

# ---- Pinned versions ---------------------------------------------------------
export KIND_VERSION="v0.33.0"
export KIND_NODE_IMAGE="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
export KUBECTL_VERSION="v1.37.0"
export HELM_VERSION="v3.16.2"
export CRANE_VERSION="v0.22.1"
export COSIGN_VERSION="v3.1.3"
export GITSIGN_VERSION="0.18.0"                  # keyless git commit/tag signing (docs/13-gitsign.md)

export CHART_TRILLIAN_VERSION="0.4.0"
export CHART_REKOR_VERSION="1.8.7"               # rekor-server v1.5.4
export CHART_FULCIO_VERSION="2.11.4"             # fulcio v1.9.0
export CHART_CTLOG_VERSION="0.2.69"
export CHART_TRAEFIK_VERSION="42.0.0"            # traefik v3.7.14
export CHART_KYVERNO_VERSION="3.9.1"             # kyverno v1.19.1

export KEYCLOAK_IMAGE="quay.io/keycloak/keycloak:26.8.1"
# scaffolding TUF repo builder/server v0.7.39 (same digest the sigstore/tuf chart pins)
export TUF_SERVER_IMAGE="ghcr.io/sigstore/scaffolding/server@sha256:b5b67a4249041249b0ad97651ff57e1f3be1468d79a01a919b39f0a1952a3def"
# Host-side (docker run / kind) images are pulled BY DIGEST while online, then
# saved and used offline under these plain tags (docker save/load does not
# reliably preserve digest references).
export KIND_NODE_IMAGE_LOCAL="${KIND_NODE_IMAGE%@*}"
export TUF_SERVER_IMAGE_LOCAL="ghcr.io/sigstore/scaffolding/server:v0.7.39"
export REGISTRY_IMAGE="docker.io/library/registry:2.8.3"
export DEMO_BASE_IMAGE="docker.io/library/busybox:1.37.0"

# ---- Paths (computed by lib.sh; listed here for reference) ------------------
#   KIT_ROOT   repository root
#   PKI_DIR    ${KIT_ROOT}/pki        generated keys/certs (NEVER commit)
#   OUT_DIR    ${KIT_ROOT}/out        generated client trust material
#   BUNDLE_DIR ${KIT_ROOT}/bundle     offline bundle (images, charts, binaries)
