#!/usr/bin/env bash
# =============================================================================
# 01-build-offline-bundle.sh — run ONCE on a machine WITH internet access.
#
# Produces bundle/ (copy it to the offline laptop with the rest of the kit):
#   bundle/bin/            kind kubectl helm crane cosign jq gitsign  (linux, ${ARCH})
#   bundle/bin/windows/    cosign.exe crane.exe gitsign.exe    (optional)
#   bundle/charts/         trillian rekor fulcio ctlog traefik kyverno (.tgz)
#   bundle/images.txt      every container image the stack runs (pinned)
#   bundle/mirror/         registry:2 storage holding ALL of those images,
#                          laid out as <registry>/<repo> with digests preserved
#   bundle/images/host-images.tar   kind node, registry:2, TUF builder, demo base
#   bundle/SHA256SUMS      integrity manifest (checked by 02-load-offline-bundle.sh)
#
# Env:
#   ARCH=amd64|arm64          target laptop CPU (default: this machine)
#   WITH_WINDOWS_CLI=1        also fetch cosign.exe/crane.exe
#   DOCKERHUB_MIRROR=host     pull docker.io images through e.g. mirror.gcr.io
#                             (avoids Docker Hub rate limits; digests unchanged)
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker curl tar
case "$(uname -m)" in x86_64|amd64) DEF_ARCH=amd64 ;; aarch64|arm64) DEF_ARCH=arm64 ;; *) DEF_ARCH=amd64 ;; esac
ARCH="${ARCH:-$DEF_ARCH}"
mkdir -p "${BUNDLE_DIR}"/{bin,charts,images,mirror}
BIN="${BUNDLE_DIR}/bin"
export PATH="${BIN}:${PATH}"     # use the tools we are about to download
dl() { log "download $(basename "$2")"; curl -fsSL --retry 3 -o "$2" "$1"; }

# ---------------------------------------------------------------- tools ----
[[ -x "${BIN}/kind"    ]] || { dl "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}" "${BIN}/kind"; }
[[ -x "${BIN}/kubectl" ]] || { dl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" "${BIN}/kubectl"; }
[[ -x "${BIN}/cosign"  ]] || { dl "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${ARCH}" "${BIN}/cosign"; }
if [[ ! -x "${BIN}/gitsign" ]]; then   # no sigstore bundle is published for gitsign: check checksums.txt
  GS="gitsign_${GITSIGN_VERSION}_linux_${ARCH}"
  dl "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/${GS}" "${BIN}/gitsign"
  curl -fsSL "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/checksums.txt" \
    | grep " ${GS}$" | sed "s| ${GS}| ${BIN}/gitsign|" | sha256sum -c - >/dev/null || die "gitsign checksum mismatch"
fi
[[ -x "${BIN}/jq"      ]] || { dl "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${ARCH}" "${BIN}/jq"; }
if [[ ! -x "${BIN}/helm" ]]; then
  dl "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" /tmp/helm.tgz
  tar -xzf /tmp/helm.tgz -C /tmp && mv "/tmp/linux-${ARCH}/helm" "${BIN}/helm"
fi
if [[ ! -x "${BIN}/crane" ]]; then
  CA="x86_64"; [[ "$ARCH" == arm64 ]] && CA="arm64"
  dl "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${CA}.tar.gz" /tmp/ggcr.tgz
  tar -xzf /tmp/ggcr.tgz -C "${BIN}" crane
fi
if [[ "${WITH_WINDOWS_CLI:-0}" == 1 ]]; then
  mkdir -p "${BIN}/windows"
  dl "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-windows-amd64.exe" "${BIN}/windows/cosign.exe"
  dl "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Windows_x86_64.tar.gz" /tmp/ggcr-win.tgz
  tar -xzf /tmp/ggcr-win.tgz -C "${BIN}/windows" crane.exe
  GSW="gitsign_${GITSIGN_VERSION}_windows_amd64.exe"
  dl "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/${GSW}" "${BIN}/windows/gitsign.exe"
  curl -fsSL "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/checksums.txt" \
    | grep " ${GSW}$" | sed "s| ${GSW}| ${BIN}/windows/gitsign.exe|" | sha256sum -c - >/dev/null || die "gitsign.exe checksum mismatch"
fi
chmod +x "${BIN}"/* 2>/dev/null || true
ok "tools: $(ls "${BIN}" | tr '\n' ' ')"

# ---------------------------------------------------------------- charts ---
log "Fetching Helm charts"
helm repo add sigstore https://sigstore.github.io/helm-charts >/dev/null
helm repo add traefik  https://traefik.github.io/charts      >/dev/null
helm repo add kyverno  https://kyverno.github.io/kyverno     >/dev/null
helm repo update >/dev/null
pull_chart() { [[ -f "${BUNDLE_DIR}/charts/$2-$3.tgz" ]] || helm pull "$1/$2" --version "$3" -d "${BUNDLE_DIR}/charts"; }
pull_chart sigstore trillian "${CHART_TRILLIAN_VERSION}"
pull_chart sigstore rekor    "${CHART_REKOR_VERSION}"
pull_chart sigstore fulcio   "${CHART_FULCIO_VERSION}"
pull_chart sigstore ctlog    "${CHART_CTLOG_VERSION}"
pull_chart traefik  traefik  "${CHART_TRAEFIK_VERSION}"
pull_chart kyverno  kyverno  "${CHART_KYVERNO_VERSION}"
ok "charts: $(ls "${BUNDLE_DIR}/charts" | tr '\n' ' ')"

# ---------------------------------------------------------------- images ---
log "Rendering charts to discover every image"
H="${BUNDLE_DIR}/charts"; V="${KIT_ROOT}/config/helm"
{
  helm template t "$H/trillian-${CHART_TRILLIAN_VERSION}.tgz" -f "$V/trillian-values.yaml" --set mysql.auth.password=x --set mysql.auth.rootPassword=x
  helm template r "$H/rekor-${CHART_REKOR_VERSION}.tgz"       -f "$V/rekor-values.yaml"
  helm template f "$H/fulcio-${CHART_FULCIO_VERSION}.tgz"     -f "$V/fulcio-values.yaml"
  helm template c "$H/ctlog-${CHART_CTLOG_VERSION}.tgz"       -f "$V/ctlog-values.yaml"
  helm template t "$H/traefik-${CHART_TRAEFIK_VERSION}.tgz"   -f "$V/traefik-values.yaml" --set service.spec.clusterIP="${INGRESS_CLUSTER_IP}"
  helm template k "$H/kyverno-${CHART_KYVERNO_VERSION}.tgz"   -f "$V/kyverno-values.yaml" --skip-tests
} | grep -E '^\s+image:\s*"?[a-z0-9]' | sed -E 's/^\s+image:\s*"?([^" ]+)"?.*/\1/' >"${BUNDLE_DIR}/images.tmp"
{
  cat "${BUNDLE_DIR}/images.tmp"
  echo "${KEYCLOAK_IMAGE}"
  echo "${REGISTRY_IMAGE}"
  echo "${TUF_SERVER_IMAGE}"
} | sort -u >"${BUNDLE_DIR}/images.txt"
rm -f "${BUNDLE_DIR}/images.tmp"
ok "$(wc -l <"${BUNDLE_DIR}/images.txt") images: see bundle/images.txt"

# mirror_ref <image> -> path inside the mirror: <registry>/<repo>:<tag>
mirror_ref() {
  local ref="$1" first reg rest name digest="" tag="" last
  first="${ref%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    reg="$first"; rest="${ref#*/}"
  else
    reg="docker.io"; rest="$ref"
  fi
  [[ "$reg" == "docker.io" && "$rest" != */* ]] && rest="library/${rest}"
  name="${rest%%@*}"; [[ "$rest" == *@* ]] && digest="${rest#*@}"
  last="${name##*/}"; if [[ "$last" == *:* ]]; then tag="${last#*:}"; name="${name%:*}"; fi
  [[ -z "$tag" ]] && tag="sha256-${digest#sha256:}"
  echo "${reg}/${name}:${tag}"
}
# source_ref <image> -> where to pull from (optionally via a Docker Hub mirror)
source_ref() {
  local ref="$1" m
  m="$(mirror_ref "$ref")"
  if [[ -n "${DOCKERHUB_MIRROR:-}" && "$m" == docker.io/* ]]; then
    local rest="${m#docker.io/}"; rest="${rest%:*}"
    [[ "$ref" == *@* ]] && echo "${DOCKERHUB_MIRROR}/${rest}@${ref#*@}" || echo "${DOCKERHUB_MIRROR}/${rest}:${m##*:}"
  else
    echo "$ref"
  fi
}

log "Copying images into bundle/mirror (all platforms; digests preserved)"
docker rm -f sigstore-mirror-build >/dev/null 2>&1 || true
docker run -d --name sigstore-mirror-build -p "127.0.0.1:${MIRROR_PORT}:5000" \
  -v "${BUNDLE_DIR}/mirror:/var/lib/registry" "${REGISTRY_IMAGE}" >/dev/null
trap 'docker rm -f sigstore-mirror-build >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do curl -fs "http://${MIRROR_ADDR}/v2/" >/dev/null && break; sleep 1; done
FAIL=0
while read -r img; do
  [[ -z "$img" ]] && continue
  dst="${MIRROR_ADDR}/$(mirror_ref "$img")"
  if crane manifest "$dst" >/dev/null 2>&1 && [[ "$img" != *@* || "$(crane digest "$dst")" == "${img#*@}" ]]; then
    echo "  = $img"; continue
  fi
  src="$(source_ref "$img")"
  if crane copy --insecure "$src" "$dst" >/dev/null 2>"${BUNDLE_DIR}/copy.err"; then
    echo "  + $img"
  # A Docker Hub mirror may lack blobs for rarer platforms: fall back to the origin.
  elif [[ "$src" != "$img" ]] && crane copy --insecure "$img" "$dst" >/dev/null 2>"${BUNDLE_DIR}/copy.err"; then
    echo "  + $img (from origin)"
  else
    warn "copy failed: $img ($(tail -1 "${BUNDLE_DIR}/copy.err"))"; FAIL=1
  fi
done <"${BUNDLE_DIR}/images.txt"
rm -f "${BUNDLE_DIR}/copy.err"
[[ $FAIL -eq 0 ]] || die "some images failed to copy; re-run (already-copied images are skipped)"
ok "mirror populated: $(du -sh "${BUNDLE_DIR}/mirror" | cut -f1)"

# ---------------------------------------------------- host-side images -----
log "Saving host images (kind node, registry, TUF builder, demo base)"
# pinned-ref => offline tag. Pull by digest (integrity), save by tag.
HOST_IMAGES=(
  "${KIND_NODE_IMAGE}=${KIND_NODE_IMAGE_LOCAL}"
  "${TUF_SERVER_IMAGE}=${TUF_SERVER_IMAGE_LOCAL}"
  "${REGISTRY_IMAGE}=${REGISTRY_IMAGE}"
  "${DEMO_BASE_IMAGE}=${DEMO_BASE_IMAGE}"
)
SAVE=()
for pair in "${HOST_IMAGES[@]}"; do
  pinned="${pair%%=*}"; local_tag="${pair#*=}"
  docker pull -q --platform "linux/${ARCH}" "$(source_ref "$pinned")" >/dev/null
  docker tag "$(source_ref "$pinned")" "$local_tag"
  SAVE+=("$local_tag")
done
docker save -o "${BUNDLE_DIR}/images/host-images.tar" "${SAVE[@]}"
printf '%s\n' "${SAVE[@]}" >"${BUNDLE_DIR}/images/host-images.txt"
ok "host images: $(du -sh "${BUNDLE_DIR}/images/host-images.tar" | cut -f1)"

# ---------------------------------------------------------------- manifest -
log "Writing bundle/SHA256SUMS"
( cd "${BUNDLE_DIR}" && find bin charts images images.txt -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS )
ok "Offline bundle complete: $(du -sh "${BUNDLE_DIR}" | cut -f1). Copy the whole kit folder to the offline laptop."
