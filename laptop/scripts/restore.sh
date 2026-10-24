#!/usr/bin/env bash
# =============================================================================
# restore.sh <backups/TIMESTAMP> — rebuild on a fresh laptop/cluster with the
# same trust root and the full Rekor/CT history.
#
# Order matters:
#   1. restore pki/ and out/                     (same keys => same trust root)
#   2. cluster, ingress, registry, Keycloak       (04–07)
#   3. trillian only, then load the MySQL dump    (trees + leaves back)
#   4. rekor, fulcio, ctlog with the OLD tree IDs pinned
#      (08 passes REKOR_TREE_ID / CTLOG_TREE_ID as server.config.treeID, so
#      the createtree jobs see an existing tree and create nothing new)
#   5. TUF + policy                               (12–13)
# =============================================================================
source "$(dirname "$0")/lib.sh"
SRC="${1:?usage: restore.sh backups/<timestamp>}"; SRC="$(cd "$SRC" && pwd)"
require_cmd kubectl openssl tar gzip
( cd "$SRC" && sha256sum --quiet -c MANIFEST.sha256 ) || die "backup integrity check failed"
[[ -d "${PKI_DIR}" ]] && die "pki/ already exists; move it away first (restore never overwrites keys)"
if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then read -r -s -p "Backup passphrase: " BACKUP_PASSPHRASE; echo; fi
export BACKUP_PASSPHRASE

log "Restoring pki/ and out/"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$SRC/pki.tar.gz.enc" \
  | tar -C "${KIT_ROOT}" -xzf -
tar -C "${KIT_ROOT}" -xzf "$SRC/out.tar.gz"
load_secrets
S="${KIT_ROOT}/scripts"
"$S/02-load-offline-bundle.sh"; "$S/04-create-cluster.sh"; "$S/05-deploy-ingress.sh"
"$S/06-deploy-registry.sh"; "$S/07-deploy-keycloak.sh"

log "Restoring Keycloak users (H2 files)"
k -n keycloak scale deploy/keycloak --replicas=0 >/dev/null
k -n keycloak wait --for=delete pod -l app.kubernetes.io/name=keycloak --timeout=120s >/dev/null 2>&1 || true
k -n keycloak run h2-restore --restart=Never --image="docker.io/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e" \
  --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsGroup":0},"containers":[{"name":"r","image":"docker.io/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e","command":["sleep","300"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"keycloak-data"}}]}}' >/dev/null
k -n keycloak wait --for=condition=Ready pod/h2-restore --timeout=120s >/dev/null
k -n keycloak exec -i h2-restore -- sh -c 'rm -rf /data/* && tar -C /data -xzf - --strip-components=1' <"$SRC/keycloak-h2.tar.gz"
k -n keycloak delete pod h2-restore --wait=false >/dev/null
k -n keycloak scale deploy/keycloak --replicas=1 >/dev/null
wait_rollout keycloak deploy/keycloak 420s >/dev/null
ok "Keycloak restored"

log "Trillian + MySQL dump"
for ns in trillian-system rekor-system fulcio-system ctlog-system; do ensure_ns "$ns"; done
h upgrade --install trillian "$(chart_ref trillian "${CHART_TRILLIAN_VERSION}")" -n trillian-system \
  -f "${KIT_ROOT}/config/helm/trillian-values.yaml" \
  --set-string mysql.auth.password="${MYSQL_PASSWORD}" --set-string mysql.auth.rootPassword="${MYSQL_ROOT_PASSWORD}" \
  --wait --wait-for-jobs --timeout 15m >/dev/null
gzip -dc "$SRC/trillian.sql.gz" | k -n trillian-system exec -i deploy/trillian-mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null'
k -n trillian-system rollout restart deploy/trillian-logserver deploy/trillian-logsigner >/dev/null
ok "Merkle trees restored"

log "Deploying Rekor/Fulcio/CT log on the restored trees"
set -a; source "$SRC/tree-ids.env"; set +a
"$S/08-deploy-sigstore.sh"
"$S/12-publish-tuf.sh"
"$S/13-deploy-policy.sh"
"$S/verify-stack.sh" || true
ok "Restore complete. Old signatures should verify: cosign verify ... (docs/06 §6)"
