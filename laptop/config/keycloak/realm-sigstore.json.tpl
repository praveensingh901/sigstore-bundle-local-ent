{
  "realm": "${OIDC_REALM}",
  "displayName": "Sigstore (offline)",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "verifyEmail": false,

  "accessTokenLifespan": 300,
  "accessTokenLifespanForImplicitFlow": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "offlineSessionIdleTimeout": 2592000,
  "accessCodeLifespan": 60,
  "accessCodeLifespanUserAction": 300,
  "accessCodeLifespanLogin": 1800,
  "oauth2DeviceCodeLifespan": 600,
  "oauth2DevicePollingInterval": 5,

  "clients": [
    {
      "clientId": "${OIDC_CLIENT_ID}",
      "name": "Sigstore cosign (interactive)",
      "description": "Public client used by cosign for browser, device-code and password flows.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "implicitFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": [
        "${OIDC_REDIRECT_URL}",
        "http://localhost/*",
        "http://127.0.0.1/*",
        "urn:ietf:wg:oauth:2.0:oob"
      ],
      "webOrigins": ["+"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "oauth2.device.authorization.grant.enabled": "true",
        "access.token.lifespan": "300",
        "post.logout.redirect.uris": "+"
      },
      "defaultClientScopes": ["basic", "profile", "email", "roles", "web-origins"],
      "optionalClientScopes": ["offline_access"],
      "protocolMappers": [
        {
          "name": "audience-sigstore",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.client.audience": "${OIDC_CLIENT_ID}",
            "id.token.claim": "true",
            "access.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "${OIDC_CI_CLIENT_ID}",
      "name": "Sigstore CI (machine identity)",
      "description": "Confidential client for pipelines. Its service-account user carries ci@${DOMAIN}.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "${CI_CLIENT_SECRET}",
      "clientAuthenticatorType": "client-secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": true,
      "attributes": {
        "access.token.lifespan": "300",
        "client_credentials.use_refresh_token": "false"
      },
      "defaultClientScopes": ["basic", "profile", "email", "roles"],
      "protocolMappers": [
        {
          "name": "audience-sigstore",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.client.audience": "${OIDC_CLIENT_ID}",
            "id.token.claim": "true",
            "access.token.claim": "true"
          }
        }
      ]
    }
  ],

  "users": [
    {
      "username": "${DEMO_USER}",
      "email": "${DEMO_USER_EMAIL}",
      "emailVerified": true,
      "enabled": true,
      "firstName": "Alice",
      "lastName": "Signer",
      "credentials": [
        { "type": "password", "value": "${DEMO_USER_PASSWORD}", "temporary": false }
      ]
    },
    {
      "username": "service-account-${OIDC_CI_CLIENT_ID}",
      "email": "ci@${DOMAIN}",
      "emailVerified": true,
      "enabled": true,
      "serviceAccountClientId": "${OIDC_CI_CLIENT_ID}"
    }
  ]
}
