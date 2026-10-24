#!/usr/bin/env bash
# =============================================================================
# 12-publish-tuf.sh — build a private TUF repository and serve it in-cluster.
#
# WHY: TUF is how Sigstore clients receive trust roots securely and how you
# ROTATE them later. Kyverno (1.19) always bootstraps from a TUF mirror for
# keyless verification, and `cosign initialize --mirror --root` lets any
# workstation or CI runner pick up the private trust root with one command.
#
# Targets published (identical bytes to out/):
#   trusted_root.json            Fulcio chain + Rekor key + CT log key
#   signing_config.v0.2.json     Fulcio/Rekor/OIDC endpoints
#   fulcio_v1.crt.pem, fulcio_intermediate_v1.crt.pem, rekor.pub, ctfe.pub
#                                legacy per-key targets (older clients)
#
# Output: out/tuf/repository/ (static files), out/tuf/root.json (bootstrap
# root to distribute), out/tuf-repo.tar.gz. Deployed as Deployment "tuf" in
# namespace tuf-system behind https://tuf.sigstore.local.
#
#   scripts/12-publish-tuf.sh              build + deploy
#   scripts/12-publish-tuf.sh --build-only build only (no cluster needed)
#
# NOTE: the scaffolding builder creates fresh TUF signing keys on every run and
# metadata that expires after 6 months. Re-run this script to rotate trust or
# before expiry, then redistribute out/tuf/root.json (see docs/05 §TUF).
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker
[[ -f "${OUT_DIR}/trusted_root.json" ]] || die "run 09-configure-cosign.sh first"

STAGE="${OUT_DIR}/tuf-input"
rm -rf "${STAGE}" "${OUT_DIR}/tuf"; mkdir -p "${STAGE}" "${OUT_DIR}/tuf"
cp "${OUT_DIR}/trusted_root.json"        "${STAGE}/trusted_root.json"
cp "${OUT_DIR}/signing_config.json"      "${STAGE}/signing_config.v0.2.json"
cp "${PKI_DIR}/fulcio/root.crt"          "${STAGE}/fulcio_v1.crt.pem"
cp "${PKI_DIR}/fulcio/intermediate.crt"  "${STAGE}/fulcio_intermediate_v1.crt.pem"
cp "${PKI_DIR}/rekor/rekor.pub"          "${STAGE}/rekor.pub"
cp "${PKI_DIR}/ctlog/ctlog.pub"          "${STAGE}/ctfe.pub"
chmod 755 "${STAGE}" "${OUT_DIR}/tuf"; chmod 644 "${STAGE}"/*
chmod 777 "${OUT_DIR}/tuf"   # builder runs as a non-root UID

TUF_BUILDER="${TUF_SERVER_IMAGE_LOCAL}"
docker image inspect "$TUF_BUILDER" >/dev/null 2>&1 || TUF_BUILDER="${TUF_SERVER_IMAGE}"
log "Building TUF repository with ${TUF_BUILDER}"
docker run --rm --network none \
  -v "${STAGE}:/in:ro" -v "${OUT_DIR}/tuf:/out" \
  "${TUF_BUILDER}" \
  --mode=init --no-k8s --file-dir=/in --target-dir=/out \
  --metadata-targets=true --trusted-root=false --signing-config=false \
  >"${OUT_DIR}/tuf-build.log" 2>&1 || { cat "${OUT_DIR}/tuf-build.log"; die "TUF build failed"; }
chmod 755 "${OUT_DIR}/tuf"
[[ -f "${OUT_DIR}/tuf/repository/root.json" ]] || die "TUF build failed"
cp "${OUT_DIR}/tuf/repository/1.root.json" "${OUT_DIR}/tuf/root.json"
tar -C "${OUT_DIR}/tuf" -czf "${OUT_DIR}/tuf-repo.tar.gz" repository
EXPIRES="$(jq -r .signed.expires "${OUT_DIR}/tuf/repository/timestamp.json")"
ok "TUF repo built: $(find "${OUT_DIR}/tuf/repository/targets" -type f | wc -l) targets, metadata expires ${EXPIRES}"
echo "TUF_EXPIRES=${EXPIRES}" >"${OUT_DIR}/tuf/meta.env"

[[ "${1:-}" == "--build-only" ]] && exit 0

# ------------------------------------------------------------- deploy ------
require_cmd kubectl
ensure_tls_secret tuf-system
k -n tuf-system create configmap tuf-repo \
  --from-file=repository.tar.gz="${OUT_DIR}/tuf-repo.tar.gz" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
export TUF_SERVER_IMAGE TUF_HOST
render "${KIT_ROOT}/config/tuf/tuf.yaml.tpl" "${GEN_DIR}/tuf.yaml"
k apply -f "${GEN_DIR}/tuf.yaml" >/dev/null
# Restart so a re-published repo is picked up (config hash changes each build).
k -n tuf-system rollout restart deploy/tuf >/dev/null
wait_rollout tuf-system deploy/tuf 180s
curl -fsS --cacert "$(tls_ca)" "${TUF_URL}/root.json" | jq -e .signed.version >/dev/null \
  || die "TUF not reachable at ${TUF_URL} (hosts file? see docs/08 §DNS)"
ok "TUF mirror live at ${TUF_URL}"
echo "  clients: cosign initialize --mirror ${TUF_URL} --root ${OUT_DIR}/tuf/root.json"
