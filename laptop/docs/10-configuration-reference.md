# 10 — Configuration Reference

Every file in the kit, what it controls, and what you may safely change.
`.tpl` files are rendered by `scripts/lib.sh:render` (`${VAR}` ← exported
variable; the render fails if a placeholder is left unresolved) into `.generated/`.

## 1. Repository map

```
sigstore-offline/
├── README.md
├── config/
│   ├── env.sh                               # ALL tunables (names, versions, IPs)
│   ├── pki/extensions.cnf                   # X.509 profiles
│   ├── kind/kind-config.yaml.tpl            # cluster definition
│   ├── coredns/sigstore-zone.Corefile.tpl   # in-cluster DNS for *.sigstore.local
│   ├── keycloak/realm-sigstore.json.tpl     # realm, clients, users, token lifetimes
│   ├── keycloak/keycloak.yaml.tpl           # Keycloak Deployment/Service/Ingress/PVC
│   ├── registry/registry.yaml.tpl           # registry:2 Deployment/Service/Ingress/PVC
│   ├── tuf/tuf.yaml.tpl                     # TUF mirror Deployment/Service/Ingress
│   ├── helm/
│   │   ├── traefik-values.yaml
│   │   ├── trillian-values.yaml
│   │   ├── rekor-values.yaml
│   │   ├── fulcio-values.yaml
│   │   ├── fulcio-config-values.yaml.tpl    # OIDC issuers (+ CACert)
│   │   ├── ctlog-values.yaml
│   │   └── kyverno-values.yaml
│   └── policies/
│       ├── kyverno/verify-images.yaml.tpl                  # tested
│       ├── gatekeeper/require-digest-from-private-registry.yaml  # validated with gator
│       ├── gatekeeper/README.md
│       └── policy-controller/private-trust-root.yaml.tpl   # reference
├── scripts/      00…13 install steps, verify-stack, backup/restore, helpers
├── windows/      Setup-Hosts.ps1, cosign-windows.ps1
├── ci/           github-actions/, gitlab/, azure-devops/
├── examples/demo-app/                       # image used by the walkthrough
├── test/compose/                            # Docker-only integration test
├── docs/                                    # this documentation
├── bundle/   (generated online)  bin/ charts/ mirror/ images/ images.txt SHA256SUMS
├── pki/      (generated)         keys, certs, secrets.env, meta.env   — NEVER commit
├── out/      (generated)         trusted_root.json, signing_config.json, ca-bundle.pem, cosign.env, tuf/
└── .generated/ (generated)       rendered manifests/values, containerd certs.d
```

## 2. `config/env.sh`

| Variable | Default | Change? | Notes |
|---|---|---|---|
| `DOMAIN` | `sigstore.local` | yes, before step 3 | drives every hostname, cert SAN and identity e-mail domain. Changing later = regenerate PKI |
| `CLUSTER_NAME` | `sigstore` | yes | kube context becomes `kind-<name>`; node `<name>-control-plane` |
| `*_HOST`, `*_URL` | derived | no | |
| `INGRESS_CLUSTER_IP` | `10.96.100.100` | only inside `10.96.0.0/16` | Traefik Service IP used by CoreDNS and node hosts |
| `OIDC_REALM`, `OIDC_CLIENT_ID`, `OIDC_CI_CLIENT_ID` | `sigstore`, `sigstore`, `sigstore-ci` | yes, before step 7 | must match Fulcio config (`ClientID` = audience) |
| `OIDC_REDIRECT_URL` | `http://localhost:8765/auth/callback` | yes | registered in the realm; passed to cosign |
| `DEMO_USER`, `DEMO_USER_EMAIL` | `alice`, `alice@${DOMAIN}` | yes | |
| `CTLOG_PREFIX` | `sigstore` | keep in sync with `ctlog-values.yaml` and `fulcio-values.yaml` `ct_log_url` | |
| `MIRROR_NAME`, `MIRROR_PORT` | `sigstore-mirror`, `5000` | port yes | bound to 127.0.0.1 |
| `MIRRORED_REGISTRIES` | docker.io ghcr.io quay.io gcr.io registry.k8s.io reg.kyverno.io | add a registry if you add charts from it | |
| versions (`KIND_*`, `KUBECTL_VERSION`, `HELM_VERSION`, `CRANE_VERSION`, `COSIGN_VERSION`, `CHART_*`, images) | pinned | only with a new online bundle build | tested together |
| `KIND_NODE_IMAGE_LOCAL`, `TUF_SERVER_IMAGE_LOCAL` | tags | no | offline names of host-side images |

## 3. Generated secrets (`pki/secrets.env`)

| Variable | Used by |
|---|---|
| `FULCIO_ROOT_PASSWORD` | root key (offline ops only) |
| `FULCIO_CA_PASSWORD` | intermediate key → Secret `fulcio-server-secret/password` |
| `REKOR_SIGNER_PASSWORD` | Rekor `--rekor_server.signer-passwd` |
| `CTLOG_KEY_PASSWORD` | Secret `ctlog-signer/password` |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak bootstrap admin |
| `DEMO_USER_PASSWORD` | user alice |
| `CI_CLIENT_SECRET` | client `sigstore-ci` |
| `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD` | Trillian MySQL |

`pki/meta.env`: `TRUST_START_TIME` — validity start for Rekor/CT keys in
`trusted_root.json` and services in `signing_config.json`.

## 4. `config/pki/extensions.cnf`

| Section | Applied to | Key extensions |
|---|---|---|
| `tls_server` + `tls_sans` | wildcard TLS cert | `CA:FALSE`, `digitalSignature`, `serverAuth`, SANs for every host + `localhost`, `127.0.0.1` |
| `fulcio_root` | (reference; root uses `-addext` equivalents) | `CA:TRUE pathlen:1`, `keyCertSign,cRLSign` |
| `fulcio_intermediate` | Fulcio issuing CA | `CA:TRUE pathlen:0`, `keyCertSign,cRLSign`, **`extendedKeyUsage=codeSigning`** |

## 5. Helm values — key by key

### `traefik-values.yaml` (chart traefik 42.0.0)
| Key | Value | Purpose |
|---|---|---|
| `deployment.kind/replicas` | Deployment/1 | |
| `nodeSelector.ingress-ready` + control-plane toleration | `"true"` | run where host ports are mapped |
| `ingressClass.{enabled,isDefaultClass,name}` | true/true/traefik | charts reference `className: traefik` |
| `providers.kubernetesIngress.enabled` | true | serve `Ingress` objects |
| `ports.web.hostPort` + `http.redirections.entryPoint` | 80 → websecure | force HTTPS |
| `ports.websecure.hostPort` | 443 | |
| `ports.websecure.transport.respondingTimeouts` | read/write 0, idle 600s | large pushes |
| `tlsStore.default.defaultCertificate.secretName` | `sigstore-tls` | default cert |
| `service.spec.type` (+ `clusterIP` via `--set`) | ClusterIP / 10.96.100.100 | fixed target for DNS |
| `log.level`, `accessLog.enabled` | INFO, true | |

### `trillian-values.yaml` (chart trillian 0.4.0)
| Key | Value |
|---|---|
| `forceNamespace`, `fullnameOverride` | `trillian-system`, `trillian` |
| `mysql.fullnameOverride`, `mysql.auth.username` | `trillian-mysql`, `trillian` |
| `mysql.auth.password/rootPassword` | `--set-string` from secrets |
| `mysql.persistence.size` | 5Gi |
| `logServer.name/fullnameOverride`, `portRPC`, `portHTTP` | `trillian-logserver`, 8091, 8090 |
| `logSigner.name/fullnameOverride` | `trillian-logsigner` (`forceMaster: true` default) |
| `createdb.dbname` | `trillian` |

### `rekor-values.yaml` (chart rekor 1.8.7)
| Key | Value | Purpose |
|---|---|---|
| `server.signer` | `/var/run/rekor-signer/rekor.key` | file signer (not `memory`) |
| `server.signerFileSecretOptions.*` | Secret `rekor-signer`, key `private` → file `rekor.key` | mounts our key |
| `server.extraArgs[0]` | `--rekor_server.signer-passwd=…` (`--set-string`) | decrypt key |
| `server.config.treeID` | unset (or `REKOR_TREE_ID` on restore) | pin an existing tree |
| `server.ingress.*` | traefik, `rekor.sigstore.local`, TLS `sigstore-tls` | |
| `server.attestation_storage` | enabled, 2Gi PVC | stores attestations |
| `trillian.enabled` | false | Trillian is its own release |
| `trillian.forceNamespace`, `trillian.logServer.{name,portRPC,portHTTP}` | `trillian-system`, `trillian-logserver`, 8091, 8090 | where to find Trillian |

### `fulcio-values.yaml` (chart fulcio 2.11.4)
| Key | Value | Purpose |
|---|---|---|
| `server.secret` | `fulcio-server-secret` | keys `private`, `cert`, `password` |
| `server.args.certificateAuthority` | `fileca` | |
| `server.args.ct_log_url` | `http://ctlog.ctlog-system.svc/sigstore` | |
| `server.logging.production` | true | JSON logs |
| `server.ingress.http.*` | traefik, `fulcio.sigstore.local`, TLS | gRPC ingress disabled |
| `createcerts.enabled` | false | don't generate a throw-away CA |
| `ctlog.enabled` | false | CT log is its own release |

### `fulcio-config-values.yaml.tpl`
`config.format: json`, `config.contents.OIDCIssuers[<issuer>]` with
`IssuerURL`, `ClientID`, `Type: email`, `Description`, `CACert` (PEM of
`pki/tls/ca.crt`). Add more issuers here (docs/04 §3).

### `ctlog-values.yaml` (chart ctlog 0.2.69)
| Key | Value |
|---|---|
| `createctconfig.logPrefix` | `sigstore` |
| `createctconfig.fulcioURL` | `http://fulcio-server.fulcio-system.svc` |
| `createctconfig.privateSecret` / `privateKeyPasswordSecretName` | `ctlog-signer` (keys `private`, `password`) |
| `createctconfig.pubkeysecret` | `ctlog-public-key` |
| `trillian.namespace`, `trillian.logServer.{name,portRPC}` | `trillian-system`, `trillian-logserver`, 8091 |
| `server.config.treeID` | unset (or `CTLOG_TREE_ID` on restore) |

### `kyverno-values.yaml` (chart kyverno 3.9.1)
Single replicas + modest requests for each controller;
`global.caCertificates.data` injected with `--set-file` (TLS root);
`config.resourceFiltersExcludeNamespaces: [kube-system, kyverno]`.

## 6. Kubernetes manifests (templates)

| Template | Objects | Notable settings |
|---|---|---|
| `kind/kind-config.yaml.tpl` | Cluster | `apiServerAddress 127.0.0.1:6443`; ports 80/443 on 127.0.0.1; `extraMounts` certs.d; label `ingress-ready` |
| `registry/registry.yaml.tpl` | NS, PVC 10Gi, Deployment, Service, Ingress | non-root 1000, read-only rootfs, `REGISTRY_HTTP_RELATIVEURLS=true`, delete enabled |
| `keycloak/keycloak.yaml.tpl` | NS, PVC 1Gi, Deployment, Service, Ingress | `start --import-realm`, `KC_HOSTNAME`, `KC_PROXY_HEADERS=xforwarded`, probes on :9000 |
| `tuf/tuf.yaml.tpl` | NS, Deployment, Service, Ingress | init container untars ConfigMap `tuf-repo`; server `--mode=serve`; non-root, read-only |
| `coredns/sigstore-zone.Corefile.tpl` | CoreDNS server block | `template IN A sigstore.local` → Traefik IP; AAAA → NOERROR |

## 7. Realm (`keycloak/realm-sigstore.json.tpl`)

See docs/02 §7.1 for the table. Change token lifetimes at realm level
(`accessTokenLifespan`) or per client (`attributes.access.token.lifespan`).

## 8. Kyverno policy (`policies/kyverno/verify-images.yaml.tpl`)

| Field | Value | Notes |
|---|---|---|
| `validationActions` | `${POLICY_ACTION}` (Deny/Audit) | |
| `failurePolicy` | Fail | |
| `matchConstraints` | Pods CREATE/UPDATE, excluding system namespaces | |
| `matchImageReferences` | `registry.sigstore.local/*` | |
| `attestors[0].cosign.keyless.identities` | issuer = realm, `subjectRegExp ^…@sigstore\.local$` | tighten per namespace |
| `attestors[0].cosign.tuf` | `mirror: https://tuf.sigstore.local`, `root.data: base64(out/tuf/root.json)` | required for offline keyless in Kyverno 1.19 |
| (no `ctlog`) | — | tlog + SCT verified offline from the bundle |
| `validations[0].expression` | `images.containers.map(image, verifyImageSignatures(image, [attestors.privateSigstore])).all(e, e > 0)` | |

## 9. Client files (`out/`)

| File | Format | Consumer |
|---|---|---|
| `trusted_root.json` | `application/vnd.dev.sigstore.trustedroot+json;version=0.1` | cosign `--trusted-root`, TUF target |
| `signing_config.json` | `application/vnd.dev.sigstore.signingconfig.v0.2+json` | cosign `--signing-config`, TUF target `signing_config.v0.2.json` |
| `ca-bundle.pem` | PEM bundle | `SSL_CERT_FILE` |
| `cosign.env` | shell | `source out/cosign.env` |
| `tuf/repository/` | TUF metadata + targets | served at `https://tuf.sigstore.local` |
| `tuf/root.json` | TUF root v1 | `cosign initialize --root`, Kyverno `tuf.root.data` |
| `last-signed-image`, `last-verify.json` | text/JSON | written by `10` |
