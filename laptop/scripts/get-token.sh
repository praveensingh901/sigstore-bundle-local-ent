#!/usr/bin/env bash
# =============================================================================
# get-token.sh — fetch an OIDC token from the private Keycloak, non-interactively.
#
#   scripts/get-token.sh user   # demo user alice, password grant -> id_token
#   scripts/get-token.sh ci     # sigstore-ci client_credentials  -> access_token
#
# Prints the raw JWT on stdout. Use with: cosign sign --identity-token "$(...)"
# For a human at a keyboard prefer the browser flow (no password handling):
#   cosign sign --oidc-redirect-url "$SIGSTORE_OIDC_REDIRECT_URL" ...
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd curl jq
load_secrets
TOKEN_URL="${OIDC_ISSUER}/protocol/openid-connect/token"
CACERT="$(tls_ca)"

case "${1:-user}" in
  user)
    curl -fsS --cacert "$CACERT" "$TOKEN_URL" \
      -d grant_type=password -d client_id="${OIDC_CLIENT_ID}" \
      -d username="${DEMO_USER}" --data-urlencode password="${DEMO_USER_PASSWORD}" \
      -d scope="openid email" | jq -er .id_token ;;
  ci)
    curl -fsS --cacert "$CACERT" "$TOKEN_URL" \
      -d grant_type=client_credentials -d client_id="${OIDC_CI_CLIENT_ID}" \
      --data-urlencode client_secret="${CI_CLIENT_SECRET}" \
      -d scope="openid email" | jq -er .access_token ;;
  *) die "usage: $0 [user|ci]" ;;
esac
