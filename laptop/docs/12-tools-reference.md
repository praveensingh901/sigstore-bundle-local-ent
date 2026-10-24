# 12 — Tools & Components Reference

What every tool is, why the kit uses it, and where it appears. Word and PowerPoint versions of this page: `docs/Sigstore-Offline-Tools-Reference.docx` and `docs/Sigstore-Offline-Tools-Overview.pptx`.

## 1. The big picture

The kit solves three problems at once — running Sigstore **privately**, running it **offline**, and **proving** it works — so it contains more tools than a typical lab. Every tool belongs to one of seven groups:

| Group | Role | Tools |
|---|---|---|
| [Workstation tools](#workstation) | Run on your laptop | 12 |
| [Cluster platform](#platform) | Plumbing inside Kubernetes | 5 |
| [Sigstore services](#sigstore) | The signing infrastructure | 6 |
| [Identity, trust & storage](#identity) | Who signs, what to trust, where artifacts live | 4 |
| [Policy enforcement](#policy) | Stop unsigned images | 3 |
| [Helper container images](#helpers) | Short-lived jobs and utilities | 6 |
| [Build & test tools](#testing) | Used to validate the kit | 8 |

### How the tools work together on one signature

| # | Step | Tool | What happens |
|---|---|---|---|
| 1 | Login | Keycloak | Developer or CI gets an OIDC token |
| 2 | Certify | Fulcio | Token → 10-minute certificate |
| 3 | Witness | CT log + Trillian | Certificate logged, SCT returned |
| 4 | Sign | cosign | Image digest signed with ephemeral key |
| 5 | Record | Rekor + Trillian | Signature logged, inclusion proof returned |
| 6 | Store | Registry | Bundle attached next to the image |
| 7 | Enforce | Kyverno + TUF | Only signed images admitted |

### Which tools do I actually need?

| Situation | Tools involved |
|---|---|
| Building the offline bundle (online, once) | Docker, Helm, crane, curl, bash — via `01-build-offline-bundle.sh` |
| Installing on the offline laptop | Docker, kind, kubectl, Helm, OpenSSL, crane, cosign, jq, curl (+ PowerShell on Windows) |
| Everyday signing and verifying | cosign (and crane to look up digests); gitsign for git commits and tags |
| Operating the stack | kubectl, `verify-stack.sh`, `backup.sh` |
| Changing or re-testing the kit | Docker Compose, Kyverno CLI, gator, shellcheck, kubeconform |

<a id="workstation"></a>
## 2. Workstation tools

Command-line tools you run on the laptop (Linux or WSL2). All except the OS basics are downloaded once by 01-build-offline-bundle.sh into bundle/bin, so nothing is installed from the internet on the offline machine.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **Docker (Engine / Desktop)** | 24+ / Desktop 4.30+ | Everything runs in containers: the kind Kubernetes node, the offline image mirror, and the TUF repository builder. |
| **WSL2 (Windows only)** | Ubuntu 22.04/24.04 | All kit scripts are bash. |
| **kind** | v0.33.0 | Gives a real, disposable Kubernetes v1.37 cluster on a laptop, using the same Helm charts as production. |
| **kubectl** | v1.37.0 | Creates namespaces and Secrets (keys, TLS), applies manifests, waits for rollouts, reads logs and runs admission dry-runs. |
| **Helm** | v3.16.2 | Installs Traefik, Trillian, Rekor, Fulcio, the CT log and Kyverno from the official charts, pinned to tested versions, using the kit's values files. |
| **crane** | v0.22.1 (go-containerregistry) | Builds the offline mirror (crane copy keeps multi-arch digests intact), resolves image digests before signing, pushes the demo image without needing Docker to trust the CA, and lists tags. |
| **cosign** | v3.1.3 | Performs keyless signing (OIDC login → Fulcio certificate → Rekor entry), verifies signatures, attaches attestations, and generates the private trusted_root.json and signing_config.json. |
| **jq** | 1.7.1 | Reads OIDC tokens, Rekor API responses, trusted roots and Kyverno output inside the scripts. |
| **OpenSSL** | 3.x (OS package) | Generates every key and certificate locally: TLS root and wildcard cert, Fulcio root + intermediate CA, Rekor and CT log signing keys. |
| **curl** | OS package | Health checks against Keycloak, Fulcio, Rekor, registry and TUF over TLS, and fetching OIDC tokens for non-interactive signing. |
| **bash, perl, coreutils** | OS packages | bash runs the scripts; perl renders the .tpl templates; sha256sum verifies the bundle; tar/base64 package the TUF repo and backups. |
| **gitsign** | v0.18.0 | Keyless signing of git commits and tags with the same Keycloak login, private Fulcio and Rekor (docs/13). |
| **PowerShell** | 5.1+ (Windows) | Edits the Windows hosts file and imports the TLS root into the Windows certificate store, so browsers, Docker Desktop and cosign.exe trust *.sigstore.local. |

### Docker (Engine / Desktop)

- **What it is:** Container runtime that runs Linux containers on your machine.
- **Why the kit uses it:** Everything runs in containers: the kind Kubernetes node, the offline image mirror, and the TUF repository builder. Docker Desktop provides this on Windows via WSL2.
- **Version:** 24+ / Desktop 4.30+
- **Used in:** 02, 04, 10, 12, test/compose
- **Offline source:** Installed beforehand (prerequisite).

```bash
docker ps   |   docker load -i bundle/images/host-images.tar
```

### WSL2 (Windows only)

- **What it is:** Windows Subsystem for Linux — a real Linux kernel inside Windows.
- **Why the kit uses it:** All kit scripts are bash. WSL2 gives Windows users the same shell, tools and paths as Linux users, and Docker Desktop integrates with it.
- **Version:** Ubuntu 22.04/24.04
- **Used in:** All scripts on Windows
- **Offline source:** Installed beforehand (prerequisite).

```bash
wsl --shutdown   (after editing the hosts file)
```

### kind

- **What it is:** Kubernetes IN Docker — runs a full Kubernetes cluster as Docker containers.
- **Why the kit uses it:** Gives a real, disposable Kubernetes v1.37 cluster on a laptop, using the same Helm charts as production. Its containerd honours /etc/containerd/certs.d, which is how the cluster pulls images from the offline mirror.
- **Version:** v0.33.0
- **Used in:** 04-create-cluster.sh, 99-teardown.sh
- **Offline source:** Binary in bundle/bin; node image kindest/node:v1.37.0 in host-images.tar.

```bash
kind create cluster --config .generated/kind-config.yaml
```

### kubectl

- **What it is:** The Kubernetes command-line client.
- **Why the kit uses it:** Creates namespaces and Secrets (keys, TLS), applies manifests, waits for rollouts, reads logs and runs admission dry-runs.
- **Version:** v1.37.0
- **Used in:** 04–08, 12, 13, verify-stack, backup/restore
- **Offline source:** Binary in bundle/bin.

```bash
kubectl --context kind-sigstore get pods -A
```

### Helm

- **What it is:** Package manager for Kubernetes; installs versioned charts with a values file.
- **Why the kit uses it:** Installs Traefik, Trillian, Rekor, Fulcio, the CT log and Kyverno from the official charts, pinned to tested versions, using the kit's values files.
- **Version:** v3.16.2
- **Used in:** 05, 08, 13; 01 (helm pull, helm template)
- **Offline source:** Binary in bundle/bin; charts as .tgz in bundle/charts.

```bash
helm upgrade --install fulcio bundle/charts/fulcio-2.11.4.tgz -f config/helm/fulcio-values.yaml
```

### crane

- **What it is:** Daemonless tool for working with container images and registries.
- **Why the kit uses it:** Builds the offline mirror (crane copy keeps multi-arch digests intact), resolves image digests before signing, pushes the demo image without needing Docker to trust the CA, and lists tags.
- **Version:** v0.22.1 (go-containerregistry)
- **Used in:** 01, 10, 13; CI examples
- **Offline source:** Binary in bundle/bin (+ crane.exe for Windows).

```bash
crane digest registry.sigstore.local/demo/hello:v1
```

### cosign

- **What it is:** Sigstore's signing and verification client.
- **Why the kit uses it:** Performs keyless signing (OIDC login → Fulcio certificate → Rekor entry), verifies signatures, attaches attestations, and generates the private trusted_root.json and signing_config.json.
- **Version:** v3.1.3
- **Used in:** 09, 10, CI examples, windows/cosign-windows.ps1
- **Offline source:** Binary in bundle/bin (+ cosign.exe for Windows).

```bash
cosign verify --trusted-root out/trusted_root.json --certificate-identity alice@sigstore.local ...
```

### gitsign

- **What it is:** Sigstore's keyless signer for git: git calls it (as `gpg.x509.program`) to sign and verify commits and tags.
- **Why the kit uses it:** Proves who wrote each commit, with the same login, Fulcio CA and Rekor log as image signing, and no GPG/SSH keys to manage.
- **Version:** v0.18.0 (checked against the release `checksums.txt`)
- **Used in:** 14-configure-gitsign.sh, export-trust.sh, test/compose/gitsign-test.sh, docs/13
- **Offline source:** Binary in bundle/bin (+ gitsign.exe for Windows).
- **Note:** reads trust from `GITSIGN_FULCIO_ROOT`, `SIGSTORE_REKOR_PUBLIC_KEY` and `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE`, not from trusted_root.json; `source out/gitsign/gitsign.env`.

```bash
gitsign verify --certificate-identity alice@sigstore.local --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore HEAD
```

### jq

- **What it is:** Command-line JSON processor.
- **Why the kit uses it:** Reads OIDC tokens, Rekor API responses, trusted roots and Kyverno output inside the scripts.
- **Version:** 1.7.1
- **Used in:** 07, 09–13, verify-stack, get-token
- **Offline source:** Static binary in bundle/bin.

```bash
jq .treeSize  (Rekor log size)
```

### OpenSSL

- **What it is:** Cryptography toolkit.
- **Why the kit uses it:** Generates every key and certificate locally: TLS root and wildcard cert, Fulcio root + intermediate CA, Rekor and CT log signing keys. Also verifies chains and compares key fingerprints.
- **Version:** 3.x (OS package)
- **Used in:** 03-generate-pki.sh, 08, verify-stack, backup.sh (AES encryption)
- **Offline source:** Ships with Linux / WSL.

```bash
openssl verify -CAfile pki/fulcio/root.crt pki/fulcio/intermediate.crt
```

### curl

- **What it is:** HTTP client.
- **Why the kit uses it:** Health checks against Keycloak, Fulcio, Rekor, registry and TUF over TLS, and fetching OIDC tokens for non-interactive signing.
- **Version:** OS package
- **Used in:** Most scripts, get-token.sh
- **Offline source:** Ships with Linux / WSL.

```bash
curl --cacert pki/tls/ca.crt https://rekor.sigstore.local/api/v1/log
```

### bash, perl, coreutils

- **What it is:** Shell and standard Unix utilities (tar, sha256sum, base64, sed, awk).
- **Why the kit uses it:** bash runs the scripts; perl renders the .tpl templates; sha256sum verifies the bundle; tar/base64 package the TUF repo and backups.
- **Version:** OS packages
- **Used in:** All scripts (lib.sh render())
- **Offline source:** Ship with Linux / WSL.

```bash
sha256sum -c bundle/SHA256SUMS
```

### PowerShell

- **What it is:** Windows shell.
- **Why the kit uses it:** Edits the Windows hosts file and imports the TLS root into the Windows certificate store, so browsers, Docker Desktop and cosign.exe trust *.sigstore.local.
- **Version:** 5.1+ (Windows)
- **Used in:** windows/Setup-Hosts.ps1, windows/cosign-windows.ps1
- **Offline source:** Built into Windows.

```bash
.\windows\Setup-Hosts.ps1  (Administrator)
```

<a id="platform"></a>
## 3. Cluster platform

Infrastructure the Sigstore services need: networking, DNS, storage, ingress and the image supply. None of it is Sigstore-specific, but each piece solves a concrete offline problem.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **containerd (in the kind node)** | bundled in kindest/node | Configured through hosts.toml files to fetch docker.io, ghcr.io, quay.io, gcr.io, registry.k8s.io and reg.kyverno.io images from the local mirror, and to trust the private registry's TLS certificate. |
| **Offline image mirror (registry:2)** | 2.8.3 | Replaces the internet for image pulls. |
| **Traefik** | v3.7.14 (chart 42.0.0) | Single TLS front door for keycloak, fulcio, rekor, registry and tuf .sigstore.local. |
| **CoreDNS** | bundled with Kubernetes | An extra sigstore.local zone answers every *.sigstore.local name with Traefik's IP, so Fulcio can reach Keycloak and Kyverno can reach the registry/TUF through the same TLS endpoints as the laptop. |
| **local-path-provisioner** | bundled with kind | Creates the PersistentVolumes for MySQL (transparency logs), the registry, Keycloak and Rekor attestation storage. |

### containerd (in the kind node)

- **What it is:** The container runtime Kubernetes uses to pull and run images.
- **Why the kit uses it:** Configured through hosts.toml files to fetch docker.io, ghcr.io, quay.io, gcr.io, registry.k8s.io and reg.kyverno.io images from the local mirror, and to trust the private registry's TLS certificate.
- **Version:** bundled in kindest/node
- **Used in:** 04-create-cluster.sh (.generated/containerd/certs.d)
- **Offline source:** Part of the node image.

```bash
docker exec sigstore-control-plane crictl pull ghcr.io/sigstore/fulcio:v1.9.0
```

### Offline image mirror (registry:2)

- **What it is:** A registry container on 127.0.0.1:5000 serving bundle/mirror.
- **Why the kit uses it:** Replaces the internet for image pulls. Every platform image is stored as <registry>/<repo> with its original digest, so the Helm charts' digest-pinned references work unchanged.
- **Version:** 2.8.3
- **Used in:** 01 (populate), 02 (start), 04 (attach to kind network)
- **Offline source:** Image in host-images.tar; data in bundle/mirror (≈4.2 GB).

```bash
curl http://127.0.0.1:5000/v2/_catalog
```

### Traefik

- **What it is:** Kubernetes ingress controller and reverse proxy.
- **Why the kit uses it:** Single TLS front door for keycloak, fulcio, rekor, registry and tuf .sigstore.local. Pinned to ClusterIP 10.96.100.100 so pods and the node resolve the same names to it. Chosen because ingress-nginx was retired in March 2026.
- **Version:** v3.7.14 (chart 42.0.0)
- **Used in:** 05-deploy-ingress.sh, config/helm/traefik-values.yaml
- **Offline source:** Image mirrored; chart in bundle/charts.

```bash
kubectl -n traefik logs deploy/traefik
```

### CoreDNS

- **What it is:** The cluster's DNS server.
- **Why the kit uses it:** An extra sigstore.local zone answers every *.sigstore.local name with Traefik's IP, so Fulcio can reach Keycloak and Kyverno can reach the registry/TUF through the same TLS endpoints as the laptop.
- **Version:** bundled with Kubernetes
- **Used in:** 05-deploy-ingress.sh, config/coredns/
- **Offline source:** Part of the node image.

```bash
kubectl run dnscheck --rm -it --image=busybox -- nslookup keycloak.sigstore.local
```

### local-path-provisioner

- **What it is:** Dynamic storage provisioner backed by node disk.
- **Why the kit uses it:** Creates the PersistentVolumes for MySQL (transparency logs), the registry, Keycloak and Rekor attestation storage.
- **Version:** bundled with kind
- **Used in:** All PVCs
- **Offline source:** Part of the node image.

```bash
kubectl get pvc -A
```

<a id="sigstore"></a>
## 4. Sigstore services

The core of the stack — private replacements for fulcio.sigstore.dev, rekor.sigstore.dev and the public CT log, all signing with keys you generated.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **Fulcio** | v1.9.0 (chart 2.11.4) | Turns a verified OIDC identity into a 10-minute X.509 signing certificate, issued by your intermediate CA. |
| **CT log (ct_server / ctfe)** | scaffolding v0.7.33 (chart 0.2.69) | Records every certificate Fulcio issues and returns a Signed Certificate Timestamp (SCT) embedded in the cert, so mis-issued certificates are detectable. |
| **Rekor** | v1.5.4 (chart 1.8.7) | Stores a tamper-evident record of every signature and returns an inclusion proof and signed timestamp, proving the signature was made while the short-lived certificate was valid. |
| **Trillian (log server + log signer)** | v1.8.0 (chart 0.4.0) | The storage engine under both Rekor and the CT log. |
| **MySQL (trillian db_server)** | Trillian CI image | Persists Trillian's Merkle trees — the complete transparency history. |
| **Redis** | pinned digest | Rekor's search index (artifact hash → entry UUID). |

### Fulcio

- **What it is:** Sigstore's code-signing certificate authority.
- **Why the kit uses it:** Turns a verified OIDC identity into a 10-minute X.509 signing certificate, issued by your intermediate CA. Trusts Keycloak through the CACert field and submits every certificate to the CT log.
- **Version:** v1.9.0 (chart 2.11.4)
- **Used in:** 08-deploy-sigstore.sh, fulcio-values.yaml, fulcio-config-values.yaml.tpl
- **Offline source:** Image mirrored; CA from pki/fulcio.

```bash
curl https://fulcio.sigstore.local/api/v2/configuration
```

### CT log (ct_server / ctfe)

- **What it is:** Certificate Transparency log front-end.
- **Why the kit uses it:** Records every certificate Fulcio issues and returns a Signed Certificate Timestamp (SCT) embedded in the cert, so mis-issued certificates are detectable. cosign verifies the SCT.
- **Version:** scaffolding v0.7.33 (chart 0.2.69)
- **Used in:** 08, ctlog-values.yaml (in-cluster only)
- **Offline source:** Image mirrored; key from pki/ctlog.

```bash
kubectl -n ctlog-system port-forward svc/ctlog 6962:80
```

### Rekor

- **What it is:** Sigstore's transparency log for signatures and attestations.
- **Why the kit uses it:** Stores a tamper-evident record of every signature and returns an inclusion proof and signed timestamp, proving the signature was made while the short-lived certificate was valid. Uses your file-based signer key.
- **Version:** v1.5.4 (chart 1.8.7)
- **Used in:** 08, rekor-values.yaml, 11-inspect-rekor.sh
- **Offline source:** Image mirrored; key from pki/rekor.

```bash
curl https://rekor.sigstore.local/api/v1/log
```

### Trillian (log server + log signer)

- **What it is:** Google's verifiable append-only Merkle-tree log.
- **Why the kit uses it:** The storage engine under both Rekor and the CT log. The log server accepts entries and serves proofs; the log signer sequences them into the tree.
- **Version:** v1.8.0 (chart 0.4.0)
- **Used in:** 08, trillian-values.yaml
- **Offline source:** Images mirrored.

```bash
kubectl -n trillian-system get pods
```

### MySQL (trillian db_server)

- **What it is:** Relational database.
- **Why the kit uses it:** Persists Trillian's Merkle trees — the complete transparency history. The most important data to back up.
- **Version:** Trillian CI image
- **Used in:** 08, backup.sh (mysqldump), restore.sh
- **Offline source:** Image mirrored.

```bash
mysqldump --databases trillian
```

### Redis

- **What it is:** In-memory key/value store.
- **Why the kit uses it:** Rekor's search index (artifact hash → entry UUID). Rebuildable from the log, so not backed up.
- **Version:** pinned digest
- **Used in:** rekor chart
- **Offline source:** Image mirrored.

```bash
curl -d '{"hash":"sha256:..."}' .../api/v1/index/retrieve
```

<a id="identity"></a>
## 5. Identity, trust & storage

The pieces that decide who may sign, how every client learns which keys to trust, and where signed images and their signatures are stored.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **Keycloak** | 26.8.1 | Private replacement for Google/GitHub/Microsoft login. |
| **Private OCI registry (registry:2)** | 2.8.3 | Stores your images and, next to them, the Sigstore signature and attestation bundles. |
| **TUF repository (scaffolding server)** | v0.7.39 | Distributes trusted_root.json and signing_config securely and supports rotation. |
| **Private PKI (generated)** | OpenSSL profiles | TLS root + wildcard cert protect transport; Fulcio root (offline) + intermediate (EKU codeSigning) anchor code signing; Rekor and CT keys sign log evidence. |

### Keycloak

- **What it is:** Open-source OpenID Connect identity provider.
- **Why the kit uses it:** Private replacement for Google/GitHub/Microsoft login. Issues the OIDC tokens Fulcio exchanges for certificates: browser, device-code and password flows for people (alice@sigstore.local), client_credentials for CI (ci@sigstore.local).
- **Version:** 26.8.1
- **Used in:** 07-deploy-keycloak.sh, realm-sigstore.json.tpl, get-token.sh
- **Offline source:** Image mirrored; realm imported from a Secret.

```bash
scripts/get-token.sh user
```

### Private OCI registry (registry:2)

- **What it is:** CNCF Distribution container registry.
- **Why the kit uses it:** Stores your images and, next to them, the Sigstore signature and attestation bundles. Served at https://registry.sigstore.local behind Traefik TLS.
- **Version:** 2.8.3
- **Used in:** 06-deploy-registry.sh, registry.yaml.tpl
- **Offline source:** Image mirrored.

```bash
crane catalog registry.sigstore.local
```

### TUF repository (scaffolding server)

- **What it is:** The Update Framework — signed metadata for distributing trust files.
- **Why the kit uses it:** Distributes trusted_root.json and signing_config securely and supports rotation. Clients pin one root.json; Kyverno 1.19 requires a TUF source to verify keyless signatures offline.
- **Version:** v0.7.39
- **Used in:** 12-publish-tuf.sh, config/tuf/tuf.yaml.tpl
- **Offline source:** Builder image in host-images.tar; server image mirrored.

```bash
cosign initialize --mirror https://tuf.sigstore.local --root out/tuf/root.json
```

### Private PKI (generated)

- **What it is:** Two separate certificate hierarchies plus log keys.
- **Why the kit uses it:** TLS root + wildcard cert protect transport; Fulcio root (offline) + intermediate (EKU codeSigning) anchor code signing; Rekor and CT keys sign log evidence. Separate hierarchies so one compromise doesn't imply the other.
- **Version:** OpenSSL profiles
- **Used in:** 03-generate-pki.sh, config/pki/extensions.cnf
- **Offline source:** Generated locally.

```bash
openssl x509 -in pki/fulcio/intermediate.crt -noout -ext extendedKeyUsage
```

<a id="policy"></a>
## 6. Policy enforcement

Admission controllers that check images before Kubernetes runs them.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **Kyverno** | v1.19.1 (chart 3.9.1) | Its ImageValidatingPolicy verifies every Pod image from registry.sigstore.local carries a keyless signature from your Fulcio/Rekor with an allowed identity, using trust from the private TUF mirror. |
| **OPA Gatekeeper (optional)** | v3.23.1 | Cannot verify cosign signatures itself; the kit uses it to require images from the private registry pinned by digest, alongside Kyverno. |
| **Sigstore policy-controller (reference)** | — | Alternative to Kyverno using TrustRoot + ClusterImagePolicy. |

### Kyverno

- **What it is:** Kubernetes-native policy engine.
- **Why the kit uses it:** Its ImageValidatingPolicy verifies every Pod image from registry.sigstore.local carries a keyless signature from your Fulcio/Rekor with an allowed identity, using trust from the private TUF mirror. Tested: signed admitted, unsigned denied.
- **Version:** v1.19.1 (chart 3.9.1)
- **Used in:** 13-deploy-policy.sh, kyverno-values.yaml, policies/kyverno/
- **Offline source:** Images mirrored (reg.kyverno.io).

```bash
kubectl get imagevalidatingpolicy
```

### OPA Gatekeeper (optional)

- **What it is:** Policy engine using the Rego language.
- **Why the kit uses it:** Cannot verify cosign signatures itself; the kit uses it to require images from the private registry pinned by digest, alongside Kyverno.
- **Version:** v3.23.1
- **Used in:** config/policies/gatekeeper/
- **Offline source:** Install from your own mirror if used.

```bash
kubectl apply -f require-digest-from-private-registry.yaml
```

### Sigstore policy-controller (reference)

- **What it is:** Sigstore's own admission controller.
- **Why the kit uses it:** Alternative to Kyverno using TrustRoot + ClusterImagePolicy. Provided as an untested reference.
- **Version:** —
- **Used in:** config/policies/policy-controller/
- **Offline source:** Not in the bundle.

<a id="helpers"></a>
## 7. Helper container images

Small images the charts and scripts run once or in init containers. They appear in bundle/images.txt and you may see them in kubectl get pods.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **scaffolding createdb** | v0.7.33 | Creates the trillian database schema in MySQL on first install. |
| **scaffolding createtree** | v0.7.33 | Creates a Trillian tree for Rekor and for the CT log and stores its ID in a ConfigMap (rekor-config / ctlog-config). |
| **scaffolding createctconfig** | v0.7.33 | Builds the CT log configuration: fetches Fulcio's root, loads your CT key from Secret ctlog-signer, writes Secret ctlog-secret. |
| **curlimages/curl** | 8.17.0 | Init containers that wait for Trillian / Fulcio to answer before Rekor and the CT config job start. |
| **busybox** | 1.37 / pinned digest | Trillian init containers, the TUF unpack init container, DNS check pods, the Keycloak restore pod, and the demo app's base image. |
| **Kyverno helper images** | v1.19.1 | Pre-start cleanup, CLI used by chart hooks, and readiness checks for the Kyverno install. |

### scaffolding createdb

- **What it is:** Kubernetes Job image.
- **Why the kit uses it:** Creates the trillian database schema in MySQL on first install.
- **Version:** v0.7.33
- **Used in:** trillian chart
- **Offline source:** Mirrored.

```bash
kubectl -n trillian-system logs job/trillian-createdb
```

### scaffolding createtree

- **What it is:** Kubernetes Job image.
- **Why the kit uses it:** Creates a Trillian tree for Rekor and for the CT log and stores its ID in a ConfigMap (rekor-config / ctlog-config). Skips if an ID already exists — which is what makes restore work.
- **Version:** v0.7.33
- **Used in:** rekor and ctlog charts
- **Offline source:** Mirrored.

```bash
kubectl -n rekor-system get cm rekor-config -o yaml
```

### scaffolding createctconfig

- **What it is:** Kubernetes Job image.
- **Why the kit uses it:** Builds the CT log configuration: fetches Fulcio's root, loads your CT key from Secret ctlog-signer, writes Secret ctlog-secret.
- **Version:** v0.7.33
- **Used in:** ctlog chart
- **Offline source:** Mirrored.

```bash
kubectl -n ctlog-system logs job/ctlog-createctconfig
```

### curlimages/curl

- **What it is:** Tiny image containing curl.
- **Why the kit uses it:** Init containers that wait for Trillian / Fulcio to answer before Rekor and the CT config job start.
- **Version:** 8.17.0
- **Used in:** rekor and ctlog charts
- **Offline source:** Mirrored.

### busybox

- **What it is:** Minimal Linux userland in one image.
- **Why the kit uses it:** Trillian init containers, the TUF unpack init container, DNS check pods, the Keycloak restore pod, and the demo app's base image.
- **Version:** 1.37 / pinned digest
- **Used in:** trillian chart, tuf.yaml.tpl, 05, restore.sh, examples/demo-app
- **Offline source:** Mirrored + host-images.tar.

### Kyverno helper images

- **What it is:** kyvernopre, kyverno-cli, readiness-checker.
- **Why the kit uses it:** Pre-start cleanup, CLI used by chart hooks, and readiness checks for the Kyverno install.
- **Version:** v1.19.1
- **Used in:** kyverno chart
- **Offline source:** Mirrored.

<a id="testing"></a>
## 8. Build & test tools

Not needed to run the stack. Used to prove the kit works (test/compose/run.sh) and to lint it. Useful if you change the kit.

| Tool | Version | Purpose in this kit |
|---|---|---|
| **Docker Compose** | v2 (Docker plugin) | Runs the same Sigstore images and arguments as the charts, without Kubernetes, for the end-to-end offline integration test. |
| **nginx (test gateway)** | 1.27 | Stands in for Traefik in the Docker test: TLS termination and the *.sigstore.local names. |
| **Toolbox image (buildpack-deps)** | bookworm-curl | A stand-in laptop on an --internal network with no internet, proving every client step works air-gapped. |
| **createtree (Trillian CLI)** | v1.7.2 | Creates Trillian trees in the Docker test (in Kubernetes the createtree Job does it). |
| **Kyverno CLI** | v1.19.1 | Proved the ImageValidatingPolicy admits signed and denies unsigned images, against the live registry and TUF. |
| **gator** | v3.23.1 | Validated the Gatekeeper digest/registry constraint. |
| **shellcheck** | v0.10.0 | Linted every script for bugs. |
| **kubeconform** | v0.6.7 | Validated the registry, Keycloak and TUF manifests against the Kubernetes API schema. |

### Docker Compose

- **What it is:** Runs multi-container apps from one YAML file.
- **Why the kit uses it:** Runs the same Sigstore images and arguments as the charts, without Kubernetes, for the end-to-end offline integration test.
- **Version:** v2 (Docker plugin)
- **Used in:** test/compose/docker-compose.yml
- **Offline source:** Ships with Docker.

```bash
test/compose/run.sh
```

### nginx (test gateway)

- **What it is:** Web server / reverse proxy.
- **Why the kit uses it:** Stands in for Traefik in the Docker test: TLS termination and the *.sigstore.local names.
- **Version:** 1.27
- **Used in:** test/compose/nginx.conf
- **Offline source:** Test only.

### Toolbox image (buildpack-deps)

- **What it is:** Debian image with bash, curl, openssl.
- **Why the kit uses it:** A stand-in laptop on an --internal network with no internet, proving every client step works air-gapped.
- **Version:** bookworm-curl
- **Used in:** test/compose/run.sh
- **Offline source:** Test only.

### createtree (Trillian CLI)

- **What it is:** Trillian admin client.
- **Why the kit uses it:** Creates Trillian trees in the Docker test (in Kubernetes the createtree Job does it).
- **Version:** v1.7.2
- **Used in:** test/compose/run.sh
- **Offline source:** Build with go install.

```bash
createtree --admin_server=127.0.0.1:18091
```

### Kyverno CLI

- **What it is:** Offline Kyverno policy evaluator.
- **Why the kit uses it:** Proved the ImageValidatingPolicy admits signed and denies unsigned images, against the live registry and TUF.
- **Version:** v1.19.1
- **Used in:** test/compose/run.sh (optional)
- **Offline source:** Optional download.

```bash
kyverno apply policy.yaml --resource pods.yaml
```

### gator

- **What it is:** Gatekeeper's CLI test tool.
- **Why the kit uses it:** Validated the Gatekeeper digest/registry constraint.
- **Version:** v3.23.1
- **Used in:** docs/11 test report
- **Offline source:** Optional.

```bash
gator test -f template.yaml -f pods.yaml
```

### shellcheck

- **What it is:** Static analyser for shell scripts.
- **Why the kit uses it:** Linted every script for bugs.
- **Version:** v0.10.0
- **Used in:** Development
- **Offline source:** Optional.

```bash
shellcheck -x scripts/*.sh
```

### kubeconform

- **What it is:** Kubernetes manifest schema validator.
- **Why the kit uses it:** Validated the registry, Keycloak and TUF manifests against the Kubernetes API schema.
- **Version:** v0.6.7
- **Used in:** Development
- **Offline source:** Optional.

```bash
kubeconform -strict file.yaml
```

## 9. Kit scripts and what they do

| Script | Purpose |
|---|---|
| `00-check-prereqs.sh` | Checks Docker resources, ports, kernel limits, bundled tools and hosts entries. |
| `01-build-offline-bundle.sh` | ONLINE ONLY. Downloads tools and charts, mirrors all 25 images with digests, saves host images, writes checksums. |
| `02-load-offline-bundle.sh` | Verifies checksums, loads host images, starts the local image mirror. |
| `03-generate-pki.sh` | Generates all keys, certificates and random passwords into pki/. |
| `04-create-cluster.sh` | Creates the kind cluster wired to the mirror and private registry. |
| `05-deploy-ingress.sh` | Installs Traefik, TLS secrets and the CoreDNS *.sigstore.local zone. |
| `06-deploy-registry.sh` | Deploys the private OCI registry. |
| `07-deploy-keycloak.sh` | Deploys Keycloak, imports the realm, smoke-tests a token. |
| `08-deploy-sigstore.sh` | Installs Trillian, Rekor, Fulcio and the CT log; verifies they use your keys. |
| `09-configure-cosign.sh` | Creates trusted_root.json, signing_config.json, CA bundle, cosign.env. |
| `10-sign-and-verify.sh` | Builds, pushes, keyless-signs and verifies the demo image. |
| `11-inspect-rekor.sh` | Shows the Rekor log state and recent entries with signer certificates. |
| `12-publish-tuf.sh` | Builds and serves the private TUF trust mirror. |
| `13-deploy-policy.sh` | Installs Kyverno and the signature policy; tests admit/deny. |
| `install-all.sh` | Runs the whole offline install in order. |
| `verify-stack.sh` | PASS/FAIL health report for every component. |
| `get-token.sh` | Fetches an OIDC token (user or CI) for non-interactive signing. |
| `setup-hosts.sh` | Adds *.sigstore.local to /etc/hosts and optionally trusts the TLS root. |
| `fix-node-dns.sh` | Re-adds node DNS entries after a reboot. |
| `backup.sh / restore.sh` | Encrypted backup of keys + log database; full rebuild with history. |
| `99-teardown.sh` | Deletes the cluster (and with --purge, the trust root). |

### Key files the tools produce

| Path | What it is |
|---|---|
| `pki/` | All private keys, certificates and passwords. Never commit; back up encrypted. |
| `out/trusted_root.json` | What to trust: Fulcio CA chain, Rekor key, CT log key. |
| `out/signing_config.json` | Where to sign: Fulcio, Rekor and OIDC URLs. |
| `out/tuf/root.json` | TUF bootstrap root distributed to clients and Kyverno. |
| `out/cosign.env` | Shell environment for cosign (CA bundle and trust file paths). |
| `bundle/` | Offline bundle: tools, charts, image mirror, host images (≈5.1 GB). |
| `config/env.sh` | All names, IPs and pinned versions in one place. |
