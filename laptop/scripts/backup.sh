#!/usr/bin/env bash
# =============================================================================
# backup.sh — capture everything needed to rebuild the stack with the SAME
# trust root and the SAME transparency-log history.
#
#   backups/<UTC timestamp>/
#     pki.tar.gz.enc        pki/ (all keys + secrets.env), AES-256 encrypted
#     out.tar.gz            trusted_root.json, signing_config.json, TUF repo
#     trillian.sql.gz       full MySQL dump (Rekor + CT log Merkle trees)
#     tree-ids.env          Trillian tree IDs of the Rekor and CT logs
#     keycloak-realm.json   realm/clients/roles (no users)
#     keycloak-h2.tar.gz    Keycloak DB files (users, sessions)
#     rekor-attestations.tar.gz  Rekor attestation storage PVC
#     MANIFEST.sha256
#
#   BACKUP_PASSPHRASE=... scripts/backup.sh    (prompted when unset)
# Redis is NOT backed up: it is only a search index, rebuilt from the log.
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd kubectl openssl tar gzip
load_secrets
TS="$(date -u +%Y%m%dT%H%M%SZ)"; DEST="${KIT_ROOT}/backups/${TS}"
mkdir -p "$DEST"; chmod 700 "$DEST"
if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then read -r -s -p "Backup passphrase: " BACKUP_PASSPHRASE; echo; fi
export BACKUP_PASSPHRASE

log "PKI (encrypted)"
tar -C "${KIT_ROOT}" -czf - pki | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -pass env:BACKUP_PASSPHRASE -out "$DEST/pki.tar.gz.enc"
log "Client trust material"
tar -C "${KIT_ROOT}" -czf "$DEST/out.tar.gz" out

log "Trillian MySQL dump (consistent snapshot)"
k -n trillian-system exec deploy/trillian-mysql -- sh -c \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --databases trillian 2>/dev/null' \
  | gzip >"$DEST/trillian.sql.gz"
[[ $(gzip -dc "$DEST/trillian.sql.gz" | grep -c 'CREATE TABLE') -ge 5 ]] || die "MySQL dump looks empty"

log "Trillian tree IDs"
{
  echo "REKOR_TREE_ID=$(k -n rekor-system get configmap rekor-config -o jsonpath='{.data.treeID}')"
  echo "CTLOG_TREE_ID=$(k -n ctlog-system get configmap ctlog-config -o jsonpath='{.data.treeID}')"
} >"$DEST/tree-ids.env"
grep -qE '^REKOR_TREE_ID=[0-9]+$' "$DEST/tree-ids.env" || die "could not read Rekor tree ID"
cat "$DEST/tree-ids.env" | sed 's/^/  /'

log "Keycloak realm export (admin REST API)"
ADMIN_TOKEN="$(curl -fsS --cacert "$(tls_ca)" "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin \
  --data-urlencode password="${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)"
curl -fsS --cacert "$(tls_ca)" -X POST -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://${KEYCLOAK_HOST}/admin/realms/${OIDC_REALM}/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  >"$DEST/keycloak-realm.json"
k -n keycloak exec deploy/keycloak -- tar -C /opt/keycloak/data -czf - h2 >"$DEST/keycloak-h2.tar.gz"

log "Rekor attestation storage"
k -n rekor-system exec deploy/rekor-server -- tar -C /var/run -czf - attestations \
  >"$DEST/rekor-attestations.tar.gz" 2>/dev/null || warn "attestation storage not backed up (no tar in image); use a volume snapshot"

( cd "$DEST" && sha256sum ./* >MANIFEST.sha256 )
ok "Backup written to ${DEST} ($(du -sh "$DEST" | cut -f1))"
warn "Store it OFF this laptop. Without pki.tar.gz.enc + passphrase the trust root cannot be restored."
