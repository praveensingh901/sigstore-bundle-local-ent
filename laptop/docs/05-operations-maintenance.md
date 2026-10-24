# 05 — Operations & Maintenance Guide

## 1. Daily operations

| Task | Command |
|---|---|
| Health report | `scripts/verify-stack.sh` |
| Start after laptop reboot | `docker start sigstore-mirror` (auto with `--restart unless-stopped`), kind node restarts with Docker, then `scripts/fix-node-dns.sh` |
| Stop everything (keep data) | `docker stop sigstore-control-plane sigstore-mirror` |
| Start again | `docker start sigstore-mirror sigstore-control-plane && scripts/fix-node-dns.sh` |
| Pod status | `kubectl --context kind-sigstore get pods -A` |
| Logs | see §3 |

Add a shell alias: `alias ks='kubectl --context kind-sigstore'`.

## 2. Service endpoints

| Service | URL | Health |
|---|---|---|
| Keycloak | `https://keycloak.sigstore.local` | `/realms/sigstore/.well-known/openid-configuration` |
| Fulcio | `https://fulcio.sigstore.local` | `/healthz`, `/api/v1/rootCert`, `/api/v2/configuration` |
| Rekor | `https://rekor.sigstore.local` | `/api/v1/log`, `/api/v1/log/publicKey` |
| CT log | `http://ctlog.ctlog-system.svc/sigstore` (in-cluster) | `/ct/v1/get-sth`, `/ct/v1/get-roots` |
| Registry | `https://registry.sigstore.local` | `/v2/` |
| TUF | `https://tuf.sigstore.local` | `/timestamp.json` |

CT log from the laptop:

```bash
kubectl --context kind-sigstore -n ctlog-system port-forward svc/ctlog 6962:80 &
curl -s http://127.0.0.1:6962/sigstore/ct/v1/get-sth | jq
```

## 3. Logs and metrics

```bash
ks -n fulcio-system   logs deploy/fulcio-server  --tail=100   # issuance, OIDC errors
ks -n rekor-system    logs deploy/rekor-server   --tail=100   # entries, signer
ks -n ctlog-system    logs deploy/ctlog          --tail=100   # add-pre-chain
ks -n trillian-system logs deploy/trillian-logsigner --tail=50 # sequencing
ks -n keycloak        logs deploy/keycloak       --tail=100   # logins
ks -n kyverno         logs deploy/kyverno-admission-controller --tail=100
ks -n traefik         logs deploy/traefik        --tail=50    # access log
```

Prometheus endpoints (scrape with your stack): Fulcio `:2112/metrics`,
Rekor `:2112/metrics`, ct_server `:6963/metrics`, Trillian `:8090/metrics`,
Keycloak `:9000/metrics`, Traefik `:9100/metrics`, Kyverno `:8000/metrics`.

Key metrics / alerts:

| Signal | Alert when |
|---|---|
| Fulcio `fulcio_new_certs` rate | drops to 0 during working hours (OIDC/CT broken) |
| Fulcio 4xx/5xx on `/api/v2/signingCert` | > 5% |
| Rekor `rekor_new_entries` | stalls while signing is attempted |
| Trillian log signer `sequencer_*` | sequencing latency > 30 s |
| MySQL PVC usage | > 70 % |
| Kyverno admission latency | p99 > 5 s; webhook failures |
| TUF `timestamp.json` expiry | < 30 days (verify-stack checks) |
| TLS cert expiry (`pki/tls/wildcard.crt`, 397 days) | < 30 days |
| Fulcio intermediate expiry (5 y) | < 180 days |

## 4. Capacity

Laptop defaults: MySQL 5 Gi, Rekor attestations 2 Gi, registry 10 Gi,
Keycloak 1 Gi. A Rekor entry is ~2–4 KB in MySQL (entry + CT pre-cert), i.e.
≈1 M signatures per 5 GB. Grow a PVC (local-path does not resize): back up,
change the size in the values file, reinstall the release, restore.

## 5. Upgrades

1. Bump versions in `config/env.sh` **on the online machine**, re-run
   `01-build-offline-bundle.sh` (only new images are copied), carry the
   updated `bundle/` across.
2. Read the chart CHANGELOGs; render and diff before applying:
   ```bash
   helm --kube-context kind-sigstore diff upgrade …     # if helm-diff plugin is bundled
   helm template … > new.yaml && kubectl --context kind-sigstore diff -f new.yaml
   ```
3. Upgrade one release at a time in dependency order: trillian → rekor →
   fulcio → ctlog → tuf → kyverno. `08-deploy-sigstore.sh` is idempotent
   (`helm upgrade --install`) and keeps tree IDs (the charts never overwrite an
   existing `treeID` key).
4. cosign: test the new client against `out/trusted_root.json` before rolling
   it to CI (trusted-root / signing-config media types can change between
   major versions; regenerate them with the new cosign via `09`).
5. Run `verify-stack.sh` and `AUTH=password scripts/10-sign-and-verify.sh`.

## 6. Key and certificate rotation

### 6.1 TLS wildcard certificate (every ≤ 397 days)

```bash
# re-issue only the server cert from the existing TLS root
source scripts/lib.sh
openssl req -new -key pki/tls/wildcard.key -subj "/O=Sigstore Offline Lab/CN=*.sigstore.local" -out /tmp/w.csr
DOMAIN=sigstore.local KEYCLOAK_HOST=keycloak.sigstore.local FULCIO_HOST=fulcio.sigstore.local \
REKOR_HOST=rekor.sigstore.local REGISTRY_HOST=registry.sigstore.local TUF_HOST=tuf.sigstore.local \
openssl x509 -req -in /tmp/w.csr -sha256 -days 397 -CA pki/tls/ca.crt -CAkey pki/tls/ca.key \
  -CAcreateserial -extfile config/pki/extensions.cnf -extensions tls_server -out pki/tls/wildcard.crt
cat pki/tls/wildcard.crt pki/tls/ca.crt > pki/tls/wildcard-fullchain.crt
for ns in traefik registry keycloak rekor-system fulcio-system tuf-system; do ensure_tls_secret $ns; done
```

Traefik reloads secrets automatically. Clients are unaffected (they trust the root).

### 6.2 Fulcio intermediate (before expiry or on compromise)

```bash
source scripts/lib.sh; load_secrets
# 1. new key + cert signed by the OFFLINE root (bring root.key back temporarily)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -aes-256-cbc \
  -pass env:FULCIO_CA_PASSWORD -out pki/fulcio/intermediate-2.key
openssl req -new -key pki/fulcio/intermediate-2.key -passin env:FULCIO_CA_PASSWORD \
  -subj "/O=Sigstore Offline Lab/OU=Code Signing/CN=Sigstore Offline Fulcio Intermediate CA 2" -out /tmp/i2.csr
openssl x509 -req -in /tmp/i2.csr -sha384 -days 1825 -CA pki/fulcio/root.crt -CAkey pki/fulcio/root.key \
  -passin env:FULCIO_ROOT_PASSWORD -CAcreateserial \
  -extfile config/pki/extensions.cnf -extensions fulcio_intermediate -out pki/fulcio/intermediate-2.crt
# 2. swap files (keep the old ones for the trusted root)
mv pki/fulcio/intermediate.crt pki/fulcio/intermediate-1.crt; mv pki/fulcio/intermediate.key pki/fulcio/intermediate-1.key
cp pki/fulcio/intermediate-2.crt pki/fulcio/intermediate.crt; cp pki/fulcio/intermediate-2.key pki/fulcio/intermediate.key
cat pki/fulcio/intermediate.crt pki/fulcio/root.crt > pki/fulcio/chain.pem
# 3. redeploy Fulcio with the new secret
scripts/08-deploy-sigstore.sh
```

Then build a trusted root containing **both** CAs (old one with an end time)
so signatures made before the switch keep verifying:

```bash
cat pki/fulcio/intermediate-1.crt pki/fulcio/root.crt > /tmp/chain-1.pem
cosign trusted-root create \
  --fulcio "url=https://fulcio.sigstore.local,certificate-chain=/tmp/chain-1.pem,end-time=$(date -u +%FT%TZ)" \
  --fulcio "url=https://fulcio.sigstore.local,certificate-chain=pki/fulcio/chain.pem" \
  --rekor  "url=https://rekor.sigstore.local,public-key=pki/rekor/rekor.pub,start-time=$TRUST_START_TIME" \
  --ctfe   "url=http://ctlog.ctlog-system.svc/sigstore,public-key=pki/ctlog/ctlog.pub,start-time=$TRUST_START_TIME" \
  --out out/trusted_root.json
scripts/12-publish-tuf.sh            # distribute
```

### 6.3 Rekor / CT log keys

Same pattern: generate the new key (`03-generate-pki.sh` commands for that key
only), update the Secret, restart the service, and publish a trusted root that
lists the **old key with `end-time`** and the **new key with `start-time`**
(repeat `--rekor` / `--ctfe` flags). Rekor's log ID changes with the key.

### 6.4 TUF metadata (every < 6 months)

```bash
scripts/12-publish-tuf.sh
```

The scaffolding builder generates fresh TUF keys each run, so `out/tuf/root.json`
**changes** and must be redistributed (CI runner images, Kyverno policy — rerun
`13-deploy-policy.sh`). For production use TUF tooling with persistent root
keys so clients follow root rotations automatically (docs/04 §2.2).

## 7. Keycloak administration

* Console: `https://keycloak.sigstore.local/admin` (admin / `KEYCLOAK_ADMIN_PASSWORD`).
* Add a signer: *Users → Add user*, set e-mail, **Email verified = ON**,
  set a password. Without "email verified" Fulcio rejects the token.
* Add a pipeline identity: *Clients → Create* (confidential, service accounts
  ON, standard flow OFF), add the `audience-sigstore` mapper (Audience =
  `sigstore`), set the service-account user's e-mail + verified.
* Token lifetimes: *Realm settings → Tokens* (access token 5 min is plenty).

## 8. Registry maintenance

```bash
SSL_CERT_FILE=out/ca-bundle.pem crane catalog registry.sigstore.local
SSL_CERT_FILE=out/ca-bundle.pem crane ls registry.sigstore.local/demo/hello
# garbage-collect deleted blobs (registry must be read-only/idle):
ks -n registry exec deploy/registry -- registry garbage-collect /etc/docker/registry/config.yml --delete-untagged=false
```

Never `--delete-untagged=true`: signature bundles are untagged referrers.

## 9. Routine checklist

| Frequency | Task |
|---|---|
| Daily | `verify-stack.sh`; review Fulcio issuance for unexpected identities |
| Weekly | `backup.sh`; copy backups off-laptop |
| Monthly | restore drill on a spare machine (`restore.sh`); review Kyverno policy reports (`ks get policyreport -A`) |
| Quarterly | rotate CI client secrets in Keycloak; review identities in policies |
| < 6 months | republish TUF (`12`) |
| < 13 months | rotate TLS wildcard (§6.1) |
| < 5 years | rotate Fulcio intermediate (§6.2) |
