#!/usr/bin/env bash
# =============================================================================
# 99-teardown.sh — remove the lab.
#   scripts/99-teardown.sh            delete cluster + mirror container
#   scripts/99-teardown.sh --purge    ALSO delete pki/, out/, .generated/
#                                     (destroys the trust root: every existing
#                                      signature becomes unverifiable)
# The offline bundle (bundle/) is never deleted.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker kind
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null && ok "cluster deleted" || true
docker rm -f "${MIRROR_NAME}" >/dev/null 2>&1 && ok "mirror container removed" || true
if [[ "${1:-}" == "--purge" ]]; then
  read -r -p "Type 'destroy-trust-root' to delete pki/ out/ .generated/: " a
  [[ "$a" == "destroy-trust-root" ]] || die "aborted"
  rm -rf "${PKI_DIR}" "${OUT_DIR}" "${GEN_DIR}"
  ok "PKI and generated material deleted"
fi
