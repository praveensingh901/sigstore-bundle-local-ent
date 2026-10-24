# 02 — Installation Guide (step by step)

Every step below is a script in `scripts/`. Each section shows **what the
script does**, **the exact commands it runs** (so you can run them by hand),
**the files it uses**, and **how to verify the result**. Run everything from
the kit's root folder in a **bash** shell (Linux, or WSL2 Ubuntu on Windows).

> One-shot alternative: `scripts/install-all.sh` runs steps 0 and 2–13 in order
> (≈10–15 minutes on a 4-core/16 GB laptop).

---

## Contents

0. [Prerequisites](#0-prerequisites)
1. [Phase A (online machine): build the offline bundle](#1-phase-a-online-build-the-offline-bundle)
2. [Load the bundle on the offline laptop](#2-load-the-bundle-on-the-offline-laptop)
3. [Generate all keys and certificates](#3-generate-the-pki)
4. [Create the kind cluster](#4-create-the-kind-cluster)
5. [Ingress (Traefik), TLS and DNS](#5-ingress-tls-and-dns)
6. [Private OCI registry](#6-private-oci-registry)
7. [Keycloak as the OIDC provider](#7-keycloak-oidc)
8. [Trillian, Rekor, Fulcio, CT log](#8-trillian-rekor-fulcio-ct-log)
9. [Configure cosign trust stores](#9-configure-cosign)
10. [Sign and verify](#10-sign-and-verify)
11. [Inspect Rekor](#11-inspect-rekor)
12. [Publish the private TUF mirror](#12-private-tuf-mirror)
13. [Enforce signatures with Kyverno](#13-admission-control)
14. [Final verification](#14-final-verification)

---

## 0. Prerequisites

| Item | Minimum | Notes |
|---|---|---|
| OS | Ubuntu 22.04/24.04, Fedora 40+, or Windows 10 22H2 / 11 with **WSL2** | macOS works for the same scripts but is not covered here |
| Docker | Docker Engine 24+ or Docker Desktop 4.30+ | Docker Desktop: enable *WSL integration* for your distro |
| Docker resources | **8 GiB RAM, 4 CPUs**, 40 GB disk | Docker Desktop → Settings → Resources; WSL: `%UserProfile%\.wslconfig` |
| Host tools | `bash curl openssl perl tar sha256sum base64` | present on stock Ubuntu |
| Free local ports | 80, 443, 5000, 6443 on 127.0.0.1 | IIS/"World Wide Web Publishing Service" often holds 80/443 on Windows |
| Kernel | `fs.inotify.max_user_watches ≥ 524288`, `max_user_instances ≥ 512` | kind requirement |

**Windows specifics**

```powershell
# %UserProfile%\.wslconfig
[wsl2]
memory=10GB
processors=4
```

```bash
# inside WSL (Ubuntu)
sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512" | sudo tee /etc/sysctl.d/99-kind.conf
```

The kit can live on a Windows drive (e.g. `E:\cosign\full-installation\sigstore-offline`,
reachable from WSL as `/mnt/e/cosign/full-installation/sigstore-offline`), but
Docker bind-mounts are much faster from the WSL filesystem. Recommended:

```bash
cp -r /mnt/e/cosign/full-installation/sigstore-offline ~/sigstore-offline
cd ~/sigstore-offline
chmod +x scripts/*.sh test/compose/run.sh
```

**Check:**

```bash
scripts/00-check-prereqs.sh
```

Hosts-file checks will fail until step 5 — that is expected.

---

## 1. Phase A (online): build the offline bundle

Run **once**, on any Linux/WSL machine **with** internet and Docker, then copy
the whole kit folder (including `bundle/`) to the offline laptop (USB disk,
data diode, approved transfer).

```bash
# laptop CPU: amd64 (default) or arm64; add Windows cosign.exe/crane.exe if wanted
ARCH=amd64 WITH_WINDOWS_CLI=1 scripts/01-build-offline-bundle.sh
# Docker Hub rate limits? pull docker.io images via a mirror (same digests):
DOCKERHUB_MIRROR=mirror.gcr.io scripts/01-build-offline-bundle.sh
```

What it does:

1. Downloads pinned tools into `bundle/bin/`: kind `v0.33.0`, kubectl `v1.37.0`,
   helm `v3.16.2`, crane `v0.22.1`, cosign `v3.1.3`, jq `1.7.1`.
2. `helm pull`s the pinned charts into `bundle/charts/` (see table below).
3. Renders every chart **with this kit's values** and extracts every
   `image:` → `bundle/images.txt` (plus Keycloak, registry:2, TUF server).
4. Starts a temporary `registry:2` with `bundle/mirror/` as storage and
   `crane copy`s every image into it as `<registry>/<repo>:<tag>`. `crane copy`
   copies the full multi-arch index, so **digests are preserved** and the
   charts' `@sha256:` references resolve offline.
5. Pulls host-side images by digest (kind node, registry:2, TUF builder, demo
   base), tags them, and `docker save`s them to `bundle/images/host-images.tar`.
6. Writes `bundle/SHA256SUMS`.

| Chart | Version | App |
|---|---|---|
| sigstore/trillian | 0.4.0 | Trillian v1.8.0 (scaffolding images), MySQL 8 |
| sigstore/rekor | 1.8.7 | rekor-server v1.5.4 |
| sigstore/fulcio | 2.11.4 | Fulcio v1.9.0 |
| sigstore/ctlog | 0.2.69 | ct_server (scaffolding v0.7.33) |
| traefik/traefik | 42.0.0 | Traefik v3.7.14 |
| kyverno/kyverno | 3.9.1 | Kyverno v1.19.1 |

**Verify:**

```bash
ls bundle/bin bundle/charts
wc -l bundle/images.txt
du -sh bundle/mirror bundle/images/host-images.tar
```

> **Why not `kind load docker-image`?** It drops digest references, and every
> Sigstore chart pins images by digest. A pull-through mirror keeps the charts
> unmodified and lets you add nodes later without re-loading images.

---

## 2. Load the bundle on the offline laptop

```bash
scripts/02-load-offline-bundle.sh
```

Equivalent manual commands:

```bash
( cd bundle && sha256sum --quiet -c SHA256SUMS )
docker load -i bundle/images/host-images.tar
docker run -d --name sigstore-mirror --restart unless-stopped \
  -p 127.0.0.1:5000:5000 -v "$PWD/bundle/mirror:/var/lib/registry" \
  docker.io/library/registry:2.8.3
```

**Verify:**

```bash
curl -s http://127.0.0.1:5000/v2/_catalog | jq '.repositories | length'   # ≈ 25+
curl -s http://127.0.0.1:5000/v2/ghcr.io/sigstore/fulcio/tags/list
```

The mirror is bound to `127.0.0.1` only and speaks plain HTTP; it is internal
plumbing between Docker and kind, never used by clients.

---

## 3. Generate the PKI

```bash
scripts/03-generate-pki.sh          # idempotent; --force regenerates EVERYTHING
```

Creates `pki/` (mode 0600 keys) — see [docs/01 §4](01-architecture-overview.md#4-two-separate-pkis)
for the hierarchy. The core commands, so you can reproduce or adapt them:

```bash
# Fulcio root (offline) — EC P-384, encrypted
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -aes-256-cbc -pass env:FULCIO_ROOT_PASSWORD -out pki/fulcio/root.key
openssl req -x509 -new -key pki/fulcio/root.key -passin env:FULCIO_ROOT_PASSWORD \
  -sha384 -days 3650 -subj "/O=Sigstore Offline Lab/OU=Code Signing/CN=Sigstore Offline Fulcio Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out pki/fulcio/root.crt

# Fulcio intermediate — MUST have EKU codeSigning (Fulcio refuses to start otherwise)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -aes-256-cbc -pass env:FULCIO_CA_PASSWORD -out pki/fulcio/intermediate.key
openssl req -new -key pki/fulcio/intermediate.key -passin env:FULCIO_CA_PASSWORD \
  -subj "/O=Sigstore Offline Lab/OU=Code Signing/CN=Sigstore Offline Fulcio Intermediate CA" -out int.csr
openssl x509 -req -in int.csr -sha384 -days 1825 -CA pki/fulcio/root.crt -CAkey pki/fulcio/root.key \
  -passin env:FULCIO_ROOT_PASSWORD -CAcreateserial \
  -extfile config/pki/extensions.cnf -extensions fulcio_intermediate -out pki/fulcio/intermediate.crt
cat pki/fulcio/intermediate.crt pki/fulcio/root.crt > pki/fulcio/chain.pem   # issuing cert FIRST

# Rekor signer — encrypted PKCS#8 (Rekor's file signer decrypts it with --rekor_server.signer-passwd)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  -aes-256-cbc -pass env:REKOR_SIGNER_PASSWORD -out pki/rekor/rekor.key

# CT log — LEGACY encrypted PEM ("Proc-Type: 4,ENCRYPTED"), the only encrypted form ctfe reads
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  | openssl ec -aes256 -passout env:CTLOG_KEY_PASSWORD -out pki/ctlog/ctlog.key
```

`config/pki/extensions.cnf` holds the X.509v3 profiles (`tls_server`,
`fulcio_root`, `fulcio_intermediate`) — read its comments for each extension.

**Verify:**

```bash
openssl verify -CAfile pki/fulcio/root.crt pki/fulcio/intermediate.crt
openssl x509 -in pki/fulcio/intermediate.crt -noout -ext basicConstraints,keyUsage,extendedKeyUsage
openssl x509 -in pki/tls/wildcard.crt -noout -ext subjectAltName
head -2 pki/ctlog/ctlog.key            # BEGIN EC PRIVATE KEY + Proc-Type: 4,ENCRYPTED
```

> **Immediately** copy `pki/` to two encrypted offline media (docs/06 §2).
> `pki/fulcio/root.key` should then be **deleted from the laptop**; it is only
> needed to issue a new intermediate.

---

## 4. Create the kind cluster

```bash
scripts/04-create-cluster.sh
```

1. Writes `.generated/containerd/certs.d/<registry>/hosts.toml` for every
   mirrored registry, e.g. `ghcr.io/hosts.toml`:

   ```toml
   server = "https://ghcr.io"

   [host."http://sigstore-mirror:5000/v2/ghcr.io"]
     capabilities = ["pull", "resolve"]
     override_path = true
   ```

   and `registry.sigstore.local/hosts.toml` + `ca.crt` (TLS trust for your own images).
2. Renders `config/kind/kind-config.yaml.tpl` (host ports 80/443 on 127.0.0.1,
   mounts `certs.d`, label `ingress-ready=true`) and runs
   `kind create cluster --config .generated/kind-config.yaml`.
3. `docker network connect kind sigstore-mirror` so nodes can reach the mirror by name.
4. `scripts/fix-node-dns.sh`: adds `10.96.100.100 keycloak.sigstore.local …` to each
   node's `/etc/hosts` (containerd runs outside the pod network and can't use CoreDNS).

**Verify:**

```bash
kubectl --context kind-sigstore get nodes -o wide
docker exec sigstore-control-plane cat /etc/containerd/certs.d/ghcr.io/hosts.toml
docker exec sigstore-control-plane crictl pull ghcr.io/sigstore/fulcio:v1.9.0   # served by the mirror
```

---

## 5. Ingress, TLS and DNS

```bash
scripts/05-deploy-ingress.sh
sudo scripts/setup-hosts.sh --trust-ca          # Linux / WSL shell
# Windows (Administrator PowerShell), then `wsl --shutdown`:
#   powershell -ExecutionPolicy Bypass -File .\windows\Setup-Hosts.ps1
```

### 5.1 Traefik (`config/helm/traefik-values.yaml`)

| Setting | Value | Why |
|---|---|---|
| `ports.web.hostPort` / `ports.websecure.hostPort` | 80 / 443 | receives kind's port mappings |
| `ports.web.http.redirections` | → websecure | HTTP always upgrades to HTTPS |
| `ports.websecure.transport.respondingTimeouts.readTimeout` | 0 | large image pushes |
| `tlsStore.default.defaultCertificate` | `sigstore-tls` | wildcard cert as default |
| `service.spec.type` / `clusterIP` | ClusterIP / `10.96.100.100` | fixed address for CoreDNS + node hosts |
| `nodeSelector` | `ingress-ready: "true"` | runs where the host ports are |

ingress-nginx is **not** used: the Kubernetes project retired it in March 2026.

```bash
helm upgrade --install traefik bundle/charts/traefik-42.0.0.tgz -n traefik --create-namespace \
  -f config/helm/traefik-values.yaml --set service.spec.clusterIP=10.96.100.100 --wait
```

### 5.2 TLS secrets

Every namespace that has an Ingress gets Secret `sigstore-tls` (wildcard
cert + chain + key):

```bash
kubectl -n <ns> create secret tls sigstore-tls \
  --cert=pki/tls/wildcard-fullchain.crt --key=pki/tls/wildcard.key
```

### 5.3 CoreDNS zone (`config/coredns/sigstore-zone.Corefile.tpl`)

Appended to the `coredns` ConfigMap (idempotently):

```
sigstore.local:53 {
    errors
    cache 30
    template IN A sigstore.local {
        answer "{{ .Name }} 60 IN A 10.96.100.100"
    }
    template IN AAAA sigstore.local {
        rcode NOERROR
    }
}
```

### 5.4 Laptop trust + names

* hosts: `127.0.0.1 keycloak.sigstore.local fulcio.sigstore.local rekor.sigstore.local registry.sigstore.local tuf.sigstore.local`
* TLS root: `pki/tls/ca.crt` into the OS store (needed for the **browser** login
  page and for Docker to push to the registry). cosign/crane/curl in WSL use
  `SSL_CERT_FILE=out/ca-bundle.pem` instead (step 9).

**Verify:**

```bash
getent hosts fulcio.sigstore.local                     # 127.0.0.1
curl -sv --cacert pki/tls/ca.crt https://registry.sigstore.local/ 2>&1 | grep -E "subject:|issuer:|HTTP/"
kubectl --context kind-sigstore run dnscheck --rm -it --restart=Never \
  --image=docker.io/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e \
  -- nslookup keycloak.sigstore.local                  # 10.96.100.100
```

(TLS errors here are expected until the backends exist — Traefik returns 404
for unknown hosts, but the certificate must already verify.)

---

## 6. Private OCI registry

```bash
scripts/06-deploy-registry.sh
```

Manifest: `config/registry/registry.yaml.tpl` — Namespace `registry`, 10 Gi PVC,
`registry:2.8.3` (non-root, read-only root FS), Service, Ingress
`registry.sigstore.local` (TLS `sigstore-tls`). `REGISTRY_HTTP_RELATIVEURLS=true`
because TLS terminates at Traefik.

Harbor is the production alternative (RBAC, replication, vulnerability
scanning, robot accounts); cosign v3 bundles work with any OCI 1.1 registry.

**Verify:**

```bash
curl -fsS --cacert pki/tls/ca.crt https://registry.sigstore.local/v2/ && echo OK
SSL_CERT_FILE=out/ca-bundle.pem crane catalog registry.sigstore.local   # after step 9
```

---

## 7. Keycloak (OIDC)

```bash
scripts/07-deploy-keycloak.sh
```

### 7.1 Realm (`config/keycloak/realm-sigstore.json.tpl`)

| Object | Setting | Value |
|---|---|---|
| realm `sigstore` | `accessTokenLifespan` | 300 s |
| | `ssoSessionIdleTimeout` / `MaxLifespan` | 1800 s / 36000 s |
| | `oauth2DeviceCodeLifespan` / polling | 600 s / 5 s |
| client `sigstore` | type | public, PKCE S256 |
| | flows | standard (browser), device authorization, direct access grants |
| | `redirectUris` | `http://localhost:8765/auth/callback`, `http://localhost/*`, `http://127.0.0.1/*`, `urn:ietf:wg:oauth:2.0:oob` |
| | protocol mapper | `oidc-audience-mapper` → `aud: sigstore` |
| client `sigstore-ci` | type | confidential, `client_credentials` only |
| | service-account user | `ci@sigstore.local`, `emailVerified: true` |
| user `alice` | email | `alice@sigstore.local`, `emailVerified: true` |

Passwords (`DEMO_USER_PASSWORD`, `CI_CLIENT_SECRET`, `KEYCLOAK_ADMIN_PASSWORD`)
come from `pki/secrets.env`; the rendered realm is stored as a **Secret**.

**Redirect URI note.** cosign's browser flow listens on a random port unless
told otherwise; the kit always passes `--oidc-redirect-url http://localhost:8765/auth/callback`
so an exact redirect URI is registered.

### 7.2 Deployment (`config/keycloak/keycloak.yaml.tpl`)

| Env | Value | Why |
|---|---|---|
| `KC_HOSTNAME` | `https://keycloak.sigstore.local` | fixes the issuer for every caller |
| `KC_HTTP_ENABLED` / `KC_PROXY_HEADERS` | `true` / `xforwarded` | TLS terminates at Traefik |
| `KC_DB` | `dev-file` (H2 on PVC) | laptop; use PostgreSQL in production |
| args | `start --import-realm` | production mode; imports realm once |

**Verify:**

```bash
curl -fsS --cacert pki/tls/ca.crt \
  https://keycloak.sigstore.local/realms/sigstore/.well-known/openid-configuration | jq .issuer
scripts/get-token.sh user | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss,aud,email,email_verified}'
```

Expected: `iss` = `https://keycloak.sigstore.local/realms/sigstore`, `aud` = `sigstore`,
`email_verified` = `true`. Admin console: `https://keycloak.sigstore.local/admin`
(user `admin`, password `KEYCLOAK_ADMIN_PASSWORD`).

---

## 8. Trillian, Rekor, Fulcio, CT log

```bash
scripts/08-deploy-sigstore.sh
```

### 8.1 Secrets created from `pki/`

| Secret (namespace) | Keys | Consumed by |
|---|---|---|
| `fulcio-server-secret` (fulcio-system) | `private`=intermediate.key, `cert`=chain.pem, `password`, `public` | Fulcio `--fileca-*` |
| `rekor-signer` (rekor-system) | `private`=rekor.key | Rekor file signer |
| `ctlog-signer` (ctlog-system) | `private`=ctlog.key, `password` | createctconfig `--private-secret` |
| `sigstore-tls` (rekor-system, fulcio-system) | tls.crt/tls.key | Ingress |

### 8.2 Helm releases (in this order)

```bash
helm upgrade --install trillian bundle/charts/trillian-0.4.0.tgz -n trillian-system \
  -f config/helm/trillian-values.yaml \
  --set-string mysql.auth.password=$MYSQL_PASSWORD --set-string mysql.auth.rootPassword=$MYSQL_ROOT_PASSWORD \
  --wait --wait-for-jobs --timeout 15m

helm upgrade --install rekor bundle/charts/rekor-1.8.7.tgz -n rekor-system \
  -f config/helm/rekor-values.yaml \
  --set-string "server.extraArgs[0]=--rekor_server.signer-passwd=$REKOR_SIGNER_PASSWORD" \
  --wait --wait-for-jobs --timeout 15m

helm upgrade --install fulcio bundle/charts/fulcio-2.11.4.tgz -n fulcio-system \
  -f config/helm/fulcio-values.yaml -f .generated/fulcio-config-values.yaml \
  --wait --wait-for-jobs --timeout 15m

helm upgrade --install ctlog bundle/charts/ctlog-0.2.69.tgz -n ctlog-system \
  -f config/helm/ctlog-values.yaml --wait --wait-for-jobs --timeout 15m
```

**Order matters:** the CT log's `createctconfig` Job fetches Fulcio's root over
HTTP at start-up, so Fulcio must already be serving.

### 8.3 What each values file changes (and why)

**`trillian-values.yaml`** — names everything `trillian-*` in
`trillian-system`, sets MySQL user `trillian` (passwords injected at install),
5 Gi PVC, log server RPC `:8091` / HTTP `:8090`.

**`rekor-values.yaml`**

```yaml
server:
  signer: /var/run/rekor-signer/rekor.key   # NOT "memory" (new key per restart)
  signerFileSecretOptions:
    secretName: rekor-signer
    secretMountPath: /var/run/rekor-signer
    secretMountSubPath: rekor.key
    privateKeySecretKey: private
  ingress: {className: traefik, hosts: [{host: rekor.sigstore.local, path: /}], tls: [{secretName: sigstore-tls, ...}]}
trillian:
  enabled: false                             # installed separately
  forceNamespace: trillian-system
  logServer: {name: trillian-logserver, portRPC: 8091, portHTTP: 8090}
```

**`fulcio-values.yaml`** — `certificateAuthority: fileca`, `createcerts.enabled: false`
(we bring our own CA), `ct_log_url: http://ctlog.ctlog-system.svc/sigstore`,
HTTP ingress with TLS, sub-chart `ctlog.enabled: false`.

**`fulcio-config-values.yaml.tpl`** → `.generated/fulcio-config-values.yaml`

```yaml
config:
  format: json
  contents:
    OIDCIssuers:
      "https://keycloak.sigstore.local/realms/sigstore":
        IssuerURL: "https://keycloak.sigstore.local/realms/sigstore"
        ClientID: "sigstore"
        Type: email
        CACert: |
          -----BEGIN CERTIFICATE-----
          ... pki/tls/ca.crt ...
```

This becomes `/etc/fulcio-config/config.json`. `CACert` lets the distroless
Fulcio verify Keycloak's TLS certificate.

**`ctlog-values.yaml`** — `logPrefix: sigstore`, `privateSecret: ctlog-signer`,
`privateKeyPasswordSecretName: ctlog-signer`, Trillian address
`trillian-logserver.trillian-system:8091`.

**Verify** (the script does all of this):

```bash
C="curl -fsS --cacert pki/tls/ca.crt"
$C https://fulcio.sigstore.local/api/v1/rootCert | openssl x509 -noout -subject      # our intermediate
$C https://fulcio.sigstore.local/api/v2/configuration | jq '.issuers[].issuerUrl'    # Keycloak realm
$C https://rekor.sigstore.local/api/v1/log | jq '{treeSize, treeID}'
diff <($C https://rekor.sigstore.local/api/v1/log/publicKey | openssl pkey -pubin -outform DER | sha256sum) \
     <(openssl pkey -pubin -in pki/rekor/rekor.pub -outform DER | sha256sum) && echo "Rekor key = ours"
kubectl --context kind-sigstore -n ctlog-system logs deploy/ctlog | grep -i "log_id\|prefix" | head
```

---

## 9. Configure cosign

```bash
scripts/09-configure-cosign.sh
source out/cosign.env
```

```bash
cosign trusted-root create \
  --fulcio "url=https://fulcio.sigstore.local,certificate-chain=pki/fulcio/chain.pem" \
  --rekor  "url=https://rekor.sigstore.local,public-key=pki/rekor/rekor.pub,start-time=$TRUST_START_TIME" \
  --ctfe   "url=http://ctlog.ctlog-system.svc/sigstore,public-key=pki/ctlog/ctlog.pub,start-time=$TRUST_START_TIME" \
  --out out/trusted_root.json

cosign signing-config create \
  --fulcio "url=https://fulcio.sigstore.local,api-version=1,start-time=$TRUST_START_TIME,operator=sigstore.local" \
  --rekor  "url=https://rekor.sigstore.local,api-version=1,start-time=$TRUST_START_TIME,operator=sigstore.local" \
  --rekor-config ANY \
  --oidc-provider "url=https://keycloak.sigstore.local/realms/sigstore,api-version=1,start-time=$TRUST_START_TIME,operator=sigstore.local" \
  --out out/signing_config.json
```

| File | Purpose |
|---|---|
| `out/trusted_root.json` | **what to trust** — passed as `--trusted-root` |
| `out/signing_config.json` | **where to sign** — passed as `--signing-config` |
| `out/ca-bundle.pem` | system CAs + TLS root; `SSL_CERT_FILE` for Go tools in WSL/Linux |
| `out/cosign.env` | exports the above (relative to its own location) |

`TRUST_START_TIME` (from `pki/meta.env`) is when the logs' keys became valid;
signatures with an earlier integrated time would be rejected.

**Verify:**

```bash
jq '.certificateAuthorities[0].uri, .tlogs[0].baseUrl, .ctlogs[0].logId.keyId' out/trusted_root.json
jq '.caUrls[0].url, .oidcUrls[0].url, .rekorTlogUrls[0].url' out/signing_config.json
```

---

## 10. Sign and verify

```bash
scripts/10-sign-and-verify.sh                 # browser login as alice
AUTH=device   scripts/10-sign-and-verify.sh   # device code (headless)
AUTH=password scripts/10-sign-and-verify.sh   # unattended (demo/test)
AUTH=ci       scripts/10-sign-and-verify.sh   # machine identity ci@sigstore.local
```

Full walkthrough with every command: **docs/03-keyless-signing-workflow.md**.

---

## 11. Inspect Rekor

```bash
scripts/11-inspect-rekor.sh        # log size, root hash, last 3 entries with signer certs
scripts/11-inspect-rekor.sh --index 0
```

---

## 12. Private TUF mirror

```bash
scripts/12-publish-tuf.sh
```

Builds a TUF repository (scaffolding `server --mode=init --no-k8s`) whose
targets are `trusted_root.json`, `signing_config.v0.2.json` and the legacy key
files, packs it into ConfigMap `tuf-repo`, and serves it at
`https://tuf.sigstore.local` (manifest `config/tuf/tuf.yaml.tpl`). The
bootstrap root to distribute is `out/tuf/root.json`.

**Verify:**

```bash
curl -fsS --cacert pki/tls/ca.crt https://tuf.sigstore.local/timestamp.json | jq .signed.expires
HOME=$(mktemp -d) cosign initialize --mirror https://tuf.sigstore.local --root out/tuf/root.json
```

TUF metadata produced this way **expires after 6 months** — re-run step 12
before then (`verify-stack.sh` warns at 30 days).

---

## 13. Admission control

```bash
scripts/13-deploy-policy.sh                     # Deny mode + admission tests
POLICY_ACTION=Audit scripts/13-deploy-policy.sh # report only
```

Installs Kyverno 1.19.1 (`config/helm/kyverno-values.yaml`, CA injected with
`--set-file global.caCertificates.data=pki/tls/ca.crt`) and applies
`.generated/kyverno-verify-images.yaml` rendered from
`config/policies/kyverno/verify-images.yaml.tpl`. Then it proves enforcement
with server-side dry runs: the signed image is admitted, an unsigned copy is
denied.

**Verify:**

```bash
kubectl --context kind-sigstore get imagevalidatingpolicy
kubectl --context kind-sigstore -n demo run t --image=registry.sigstore.local/demo/unsigned:v1 --dry-run=server
# Error from server: admission webhook ... denied the request: ... Image is not signed ...
```

---

## 14. Final verification

```bash
scripts/verify-stack.sh
```

Prints PASS/FAIL for platform, every namespace's pods, every endpoint (with key
fingerprints compared against `pki/`), client trust files, TUF expiry and the
policy. Exit code 0 = healthy.
