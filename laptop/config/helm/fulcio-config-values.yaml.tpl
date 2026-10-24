# Rendered by 08-deploy-sigstore.sh into .generated/fulcio-config-values.yaml
# -----------------------------------------------------------------------------
# Fulcio OIDC issuer configuration (becomes ConfigMap fulcio-server-config,
# file /etc/fulcio-config/config.json).
#
#   IssuerURL  must equal the "iss" claim in the token EXACTLY. Keycloak emits
#              https://keycloak.sigstore.local/realms/sigstore because
#              KC_HOSTNAME is pinned (see config/keycloak/keycloak.yaml).
#   ClientID   must appear in the token's "aud" claim.
#   Type       "email": the certificate SAN becomes the token's e-mail address
#              and Fulcio REQUIRES email_verified=true in the token.
#   CACert     PEM of the TLS root that signed keycloak.sigstore.local. Fulcio
#              (distroless, no system CA for our private root) uses it ONLY to
#              fetch /.well-known/openid-configuration + JWKS from Keycloak.
#              Supported since Fulcio v1.7 (pkg/config OIDCIssuer.CACert).
# -----------------------------------------------------------------------------
config:
  format: json
  contents:
    OIDCIssuers:
      "${OIDC_ISSUER}":
        IssuerURL: "${OIDC_ISSUER}"
        ClientID: "${OIDC_CLIENT_ID}"
        Type: email
        Description: "Private Keycloak realm ${OIDC_REALM}"
        CACert: |
${TLS_CA_PEM_INDENTED}
