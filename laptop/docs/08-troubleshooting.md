# 08 — Troubleshooting Guide

Start every investigation with:

```bash
scripts/verify-stack.sh
kubectl --context kind-sigstore get pods -A | grep -v -E 'Running|Completed'
```

Then find the symptom below.

---

## Bundle / images

| Symptom | Cause | Fix |
|---|---|---|
| `01-build-offline-bundle.sh`: `429 Too Many Requests` | Docker Hub anonymous rate limit | `DOCKERHUB_MIRROR=mirror.gcr.io scripts/01-build-offline-bundle.sh` (or `docker login` first); re-run — already-copied images are skipped |
| Pods `ImagePullBackOff`, event `failed to resolve reference "ghcr.io/…"` | mirror not reachable from node | `docker ps | grep sigstore-mirror`; `docker network connect kind sigstore-mirror`; `docker exec sigstore-control-plane curl -s http://sigstore-mirror:5000/v2/` |
| `ImagePullBackOff`, `not found` for one image | image missing from `bundle/images.txt` (e.g. you changed a value) | on the online machine re-run `01` (it re-renders charts), carry `bundle/mirror` across |
| `ImagePullBackOff` for `registry.sigstore.local/...` | node can't resolve/trust the private registry | `scripts/fix-node-dns.sh`; check `docker exec sigstore-control-plane cat /etc/containerd/certs.d/registry.sigstore.local/hosts.toml` |
| `02`: checksum mismatch | incomplete copy | re-copy `bundle/` (use `rsync -c` or an archive + hash) |

## Cluster / kind

| Symptom | Fix |
|---|---|
| `kind create cluster` fails: `too many open files` / kube-proxy crash | `sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512` |
| `bind: address already in use` for 80/443 | free the port (Windows: `net stop http` stops IIS/HTTP.sys users; `netstat -ano | findstr :443`), or stop other kind clusters |
| Node not Ready after reboot | `docker start sigstore-control-plane`; wait 60 s; `scripts/fix-node-dns.sh` |
| Everything slow on Windows | keep the kit under `~/` in WSL, not `/mnt/e/…`; give WSL ≥ 8 GB |

## DNS / TLS {#dns}

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (6) Could not resolve host: fulcio.sigstore.local` (laptop) | hosts file | `sudo scripts/setup-hosts.sh`; WSL: run `windows/Setup-Hosts.ps1` then `wsl --shutdown` |
| WSL loses the hosts entry after restart | WSL regenerates `/etc/hosts` | add it on the Windows side (Setup-Hosts.ps1) — WSL copies it — or set `[network] generateHosts=false` in `/etc/wsl.conf` |
| `x509: certificate signed by unknown authority` (cosign/crane in WSL) | `SSL_CERT_FILE` not set | `source out/cosign.env` |
| same error from `cosign.exe` on Windows | Windows Go uses the system store, ignores `SSL_CERT_FILE` | `windows/Setup-Hosts.ps1` imports the root into `LocalMachine\Root` |
| `docker push registry.sigstore.local/...`: `x509` | Docker daemon doesn't trust the root | Linux: `sudo scripts/setup-hosts.sh --trust-ca` (writes `/etc/docker/certs.d/registry.sigstore.local/ca.crt`); Docker Desktop: import root into Windows store + restart Docker Desktop; or push with `crane` (docs/03 §2 option B) |
| Browser shows TLS warning on Keycloak login | root not in browser/OS store | Setup-Hosts.ps1 (Windows) / `--trust-ca` (Linux; Firefox has its own store: import `pki/tls/ca.crt` manually) |
| Pod can't resolve `*.sigstore.local` | CoreDNS block missing | `kubectl -n kube-system get cm coredns -o yaml | grep -A8 sigstore.local`; re-run `05` |

## Keycloak

| Symptom | Fix |
|---|---|
| Discovery `issuer` is `http://…` or has a port | `KC_HOSTNAME` must be `https://keycloak.sigstore.local` (no port); check Traefik sends `X-Forwarded-Proto` (it does by default) |
| `Invalid parameter: redirect_uri` | cosign used a random port: pass `--oidc-redirect-url http://localhost:8765/auth/callback`; or add the exact URI in the `sigstore` client |
| `Account is not fully set up` | user has required actions (e.g. verify email); clear them in the admin console |
| Pod restarts on first start | slow laptop: the startup probe allows 5 min; check `ks -n keycloak logs deploy/keycloak` |

## Fulcio

| Log / error | Cause | Fix |
|---|---|---|
| `certificate must have extended key usage code signing set` (startup) | intermediate lacks EKU | regenerate with `extensions.cnf` profile `fulcio_intermediate` |
| `error creating provider for issuer URL … x509` | `CACert` missing/wrong in Fulcio config | re-run `08` (renders `.generated/fulcio-config-values.yaml` from `pki/tls/ca.crt`) |
| `… 502 Bad Gateway` / `503 Bootstrap in progress` at startup | Keycloak not ready yet | Fulcio retries per request; restart Fulcio after Keycloak is up (`ks -n fulcio-system rollout restart deploy/fulcio-server`) |
| cosign: `error obtaining token … 401`/`unsupported issuer` | token `iss` ≠ configured `IssuerURL` | compare `scripts/get-token.sh user | …jq .iss` with `curl …/api/v2/configuration` |
| `email_verified claim was false` | user's email not verified | set *Email verified* in Keycloak |
| `audience not satisfied` | `aud` lacks `sigstore` | add the `audience-sigstore` mapper to the client |
| `error … ct log: … connection refused` | CT log not ready | `ks -n ctlog-system get pods,jobs`; Fulcio must be up **before** the CT log's `createctconfig` Job (it fetches the root) — re-run `08` |
| `open /var/run/fulcio-secrets/key.pem: permission denied` | (only outside Kubernetes) file mode 0600 for a non-root container | mount a 0644 copy (k8s Secret volumes already are) |

## CT log

| Symptom | Fix |
|---|---|
| `ctlog-createctconfig` Job failing: `failed to decrypt private PEMKeyFile` | key not in legacy encrypted format or wrong password: `head -2 pki/ctlog/ctlog.key` must show `Proc-Type: 4,ENCRYPTED`; password from `CTLOG_KEY_PASSWORD` |
| Job failing: fetch root | Fulcio not reachable at `http://fulcio-server.fulcio-system.svc` — check Fulcio first |
| `ctlog` pod `ContainerCreating` forever | Secret `ctlog-secret` not created yet (Job still running) — check the Job logs |

## Rekor / Trillian

| Symptom | Fix |
|---|---|
| `file: provide a valid signer … permission denied` | key not readable — only outside k8s |
| `file: provide a valid signer … decrypt` | wrong `REKOR_SIGNER_PASSWORD` — compare with `pki/secrets.env`, re-run `08` |
| `stat /var/run/attestations: no such file` | attestation storage volume missing — keep `attestation_storage.persistence.enabled: true` |
| Rekor `tlog_id` 0 / empty | `rekor-createtree` Job failed: `ks -n rekor-system logs job/rekor-createtree` — usually Trillian log server not ready |
| Entries never get an inclusion proof | log **signer** not running: `ks -n trillian-system get deploy trillian-logsigner` |
| MySQL `CrashLoopBackOff` after PVC reuse with new passwords | PVC initialized with old passwords — restore old `pki/secrets.env` or wipe the PVC (data loss) |

## cosign

| Error | Fix |
|---|---|
| `no matching attestations: failed to verify certificate identity … expected SAN value` (bundles) or `no matching signatures: … none of the expected identities matched` (legacy `.sig`) | wrong `--certificate-identity`/`--certificate-oidc-issuer`; inspect: `cosign verify … --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*'` |
| `… could not verify SCT …` | `trusted_root.json` CT key ≠ deployed CT key: re-run `09` after `08`; compare with `ks -n ctlog-system get secret ctlog-public-key -o jsonpath='{.data.public}' | base64 -d` |
| `… transparency log … not found` / `checkpoint signature` | Rekor key in `trusted_root.json` differs from the running Rekor (e.g. Rekor ran with `memory` signer) — fix the signer, re-sign |
| `… integrated time … outside validity` / log not valid at time | `TRUST_START_TIME` later than the entry time — regenerate `09` (it uses `pki/meta.env`) |
| cosign tries to reach `tuf-repo-cdn.sigstore.dev` | you omitted `--trusted-root`/`--signing-config` **and** never ran `cosign initialize --mirror https://tuf.sigstore.local` |
| `MANIFEST_UNKNOWN` when verifying | signature lookup failed: check `cosign tree <image@digest>` and that you sign/verify the **same digest** |

## Kyverno {#kyverno}

| Symptom | Fix |
|---|---|
| Signed image denied: `failed to initialize TUF client (mirror="https://tuf-repo-cdn.sigstore.dev")` | policy lacks the `tuf:` block — Kyverno 1.19 always bootstraps from TUF for keyless; re-render with `13` |
| `… x509: certificate signed by unknown authority` (TUF or registry) | Kyverno lacks the CA: re-run `13` (it sets `global.caCertificates.data`) |
| `image … does not have a digest` (CLI tests) | the CLI doesn't mutate tags to digests; use `@sha256:` refs in test manifests |
| Every Pod in a namespace times out at admission | Kyverno down with `failurePolicy: Fail` — fix Kyverno, or temporarily set `validationActions: [Audit]` |
| Policy `ready: false` | `ks describe imagevalidatingpolicy require-private-sigstore-signature` — usually a CEL or schema error |

## Collect a support bundle

```bash
mkdir -p /tmp/sigstore-diag && cd /tmp/sigstore-diag
kubectl --context kind-sigstore get all,ing,cm,pvc -A -o wide > resources.txt
for d in fulcio-system/fulcio-server rekor-system/rekor-server ctlog-system/ctlog \
         trillian-system/trillian-logserver trillian-system/trillian-logsigner keycloak/keycloak tuf-system/tuf; do
  kubectl --context kind-sigstore -n "${d%/*}" logs "deploy/${d#*/}" --tail=500 > "${d#*/}.log" 2>&1
done
~/sigstore-offline/scripts/verify-stack.sh > verify.txt 2>&1
tar czf ../sigstore-diag.tgz . && echo /tmp/sigstore-diag.tgz
```

(No keys are included — never attach `pki/` to a ticket.)

## gitsign

See [13-gitsign.md §5](13-gitsign.md#5-troubleshooting). First step for any failure: `GITSIGN_LOG=/tmp/gitsign.log git commit …`, because git only prints `gpg failed to sign the data`.
