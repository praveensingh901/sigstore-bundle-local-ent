#!/usr/bin/env bash
# =============================================================================
# 07-deploy-keycloak.sh — private OIDC provider (realm "sigstore").
#
# Realm (config/keycloak/realm-sigstore.json.tpl):
#   client sigstore     public; browser (PKCE), device-code and password flows;
#                       redirect http://localhost:8765/auth/callback (+ loopback)
#   client sigstore-ci  confidential; client_credentials -> ci@sigstore.local
#   user   alice        alice@sigstore.local (emailVerified=true)
#   tokens 5 min access/ID token, 30 min SSO idle, 10 min device code
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd kubectl curl jq
load_secrets

ensure_tls_secret keycloak
export DEMO_USER_PASSWORD CI_CLIENT_SECRET
render "${KIT_ROOT}/config/keycloak/realm-sigstore.json.tpl" "${GEN_DIR}/realm-sigstore.json"
jq -e . "${GEN_DIR}/realm-sigstore.json" >/dev/null || die "rendered realm is not valid JSON"
chmod 600 "${GEN_DIR}/realm-sigstore.json"

k -n keycloak create secret generic keycloak-realm \
  --from-file=realm-sigstore.json="${GEN_DIR}/realm-sigstore.json" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k -n keycloak create secret generic keycloak-admin \
  --from-literal=password="${KEYCLOAK_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

export OIDC_ISSUER_BASE="https://${KEYCLOAK_HOST}" KEYCLOAK_IMAGE KEYCLOAK_HOST OIDC_ISSUER
render "${KIT_ROOT}/config/keycloak/keycloak.yaml.tpl" "${GEN_DIR}/keycloak.yaml"
k apply -f "${GEN_DIR}/keycloak.yaml" >/dev/null
log "Waiting for Keycloak (first start imports the realm, ~1-2 min)"
wait_rollout keycloak deploy/keycloak 420s >/dev/null

DISC="$(curl -fsS --retry 20 --retry-delay 3 --retry-all-errors --cacert "$(tls_ca)" \
  "${OIDC_ISSUER}/.well-known/openid-configuration")" \
  || die "discovery document unreachable at ${OIDC_ISSUER} (hosts file?)"
ISS="$(echo "$DISC" | jq -r .issuer)"
[[ "$ISS" == "${OIDC_ISSUER}" ]] || die "issuer mismatch: got '${ISS}', expected '${OIDC_ISSUER}'"
ok "OIDC issuer ${ISS}"
echo "$DISC" | jq -r '"  device endpoint : \(.device_authorization_endpoint)\n  token endpoint  : \(.token_endpoint)"'

log "Smoke test: password grant for ${DEMO_USER}"
TOKEN="$("${KIT_ROOT}/scripts/get-token.sh" user)"
jwt_payload "$TOKEN" | jq -r \
  '"  iss=\(.iss)\n  aud=\(.aud)\n  email=\(.email) email_verified=\(.email_verified)"' 2>/dev/null || true
ok "Keycloak issues tokens Fulcio will accept"
echo "  admin console: https://${KEYCLOAK_HOST}/admin  (admin / see pki/secrets.env KEYCLOAK_ADMIN_PASSWORD)"
