# 03 — Local Keyless Signing Workflow

End-to-end, by hand: build an image, push it to the private registry, sign it
keylessly through **your** Fulcio and Rekor, verify it with **only** your trust
root, and look at the evidence in **your** Rekor. `scripts/10-sign-and-verify.sh`
and `scripts/11-inspect-rekor.sh` automate exactly these commands.

Prerequisites: steps 0–9 of the installation guide, and in your shell:

```bash
cd ~/sigstore-offline
export PATH="$PWD/bundle/bin:$PATH"
source config/env.sh
source out/cosign.env          # SSL_CERT_FILE, SIGSTORE_TRUSTED_ROOT, SIGSTORE_SIGNING_CONFIG
```

---

## 1. Build a sample image

```bash
docker build -t registry.sigstore.local/demo/hello:v1 \
  --build-arg BASE_IMAGE=docker.io/library/busybox:1.37.0 examples/demo-app
```

`examples/demo-app/Dockerfile` serves a static page with busybox `httpd` as an
unprivileged user. The base image came from the offline bundle.

## 2. Push it to the private registry

Option A — through Docker (requires Docker to trust `pki/tls/ca.crt`:
`sudo scripts/setup-hosts.sh --trust-ca` on Linux, or `windows/Setup-Hosts.ps1`
+ restart Docker Desktop on Windows):

```bash
docker push registry.sigstore.local/demo/hello:v1
```

Option B — no Docker daemon trust needed (crane honours `SSL_CERT_FILE`):

```bash
docker save registry.sigstore.local/demo/hello:v1 -o /tmp/hello.tar
crane push /tmp/hello.tar registry.sigstore.local/demo/hello:v1
```

Resolve the **digest** — always sign digests, never tags:

```bash
DIGEST=$(crane digest registry.sigstore.local/demo/hello:v1)
IMAGE=registry.sigstore.local/demo/hello@$DIGEST
echo "$IMAGE"
```

## 3. Keyless signing

### 3a. Interactive (browser)

```bash
cosign sign --yes \
  --signing-config "$SIGSTORE_SIGNING_CONFIG" \
  --trusted-root   "$SIGSTORE_TRUSTED_ROOT" \
  --oidc-redirect-url http://localhost:8765/auth/callback \
  "$IMAGE"
```

1. cosign prints a Keycloak URL and opens your browser
   (`https://keycloak.sigstore.local/realms/sigstore/protocol/openid-connect/auth?...`).
   In WSL without a browser bridge, copy the URL into a Windows browser — the
   redirect to `localhost:8765` reaches WSL thanks to WSL2 localhost forwarding.
2. Log in as `alice` (password: `DEMO_USER_PASSWORD` in `pki/secrets.env`).
3. cosign receives the ID token on `http://localhost:8765/auth/callback`.

### 3b. Headless (device code)

```bash
cosign sign --yes --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --fulcio-auth-flow device "$IMAGE"
# -> "Enter verification code XXXX-XXXX in your browser at: https://keycloak.sigstore.local/realms/sigstore/device"
```

### 3c. Non-interactive (pre-fetched token)

```bash
TOKEN=$(scripts/get-token.sh user)      # password grant for alice (lab/testing)
TOKEN=$(scripts/get-token.sh ci)        # client_credentials for sigstore-ci (CI)
cosign sign --yes --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --identity-token "$TOKEN" "$IMAGE"
```

### What happened (output explained)

```
Generating ephemeral keys...            # P-256 key pair, memory only
Retrieving signed certificate...         # Fulcio: token -> 10-minute cert, SCT from your CT log
Successfully verified SCT...
Signing artifact...                      # signature over the image digest
tlog entry created with index: 0         # Rekor (your Trillian tree)
Pushing signature to: registry.sigstore.local/demo/hello   # Sigstore bundle via OCI referrers
```

See what is now attached to the image:

```bash
cosign tree "$IMAGE"
# 📦 Supply Chain Security Related artifacts for an image: registry.sigstore.local/demo/hello@sha256:9a59…
# └── 🔗 https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer: registry.sigstore.local/demo/hello@sha256:aead…
#    └── 🍒 sha256:2fa5…

crane ls registry.sigstore.local/demo/hello
# v1
# sha256-9a59b79d…      <- referrers index (tag-schema fallback)
```

`registry:2.8` does not implement the OCI 1.1 `/referrers` API (it returns 404),
so cosign v3 uses the spec's **tag-schema fallback**: an index tagged
`sha256-<image digest>` that lists the bundles. cosign and Kyverno both read it
transparently. Registries with the native API (Harbor 2.9+, distribution 3.x,
Zot, ACR, ECR) are used the same way.

## 4. Verify with the private trust root

```bash
cosign verify \
  --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore \
  "$IMAGE" | jq .
```

Expected:

```
Verification for registry.sigstore.local/demo/hello@sha256:... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

"verified offline" means: the Rekor inclusion proof and signed checkpoint inside
the bundle were checked against the Rekor key in `trusted_root.json` — no
network call to Rekor was needed. The SCT was checked against the CT key.

Identity matching options:

```bash
--certificate-identity-regexp '^[a-z0-9._-]+@sigstore\.local$'     # any realm user
--certificate-oidc-issuer-regexp '^https://keycloak\.sigstore\.local/realms/.*$'
```

**Negative tests (must fail):**

```bash
cosign verify --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --certificate-identity mallory@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore "$IMAGE"
# Error: no matching attestations: failed to verify certificate identity: no matching CertificateIdentity found,
#   last error: expected SAN value "mallory@sigstore.local", got "alice@sigstore.local"
# (cosign v3 verifies bundles through the attestation path; legacy .sig signatures say "no matching signatures")

# Public Sigstore trust (if a public trusted_root.json were used) would reject it too:
# the leaf chains to "Sigstore Offline Fulcio Root CA", not the public Fulcio root.
```

## 5. Sign and verify other things

```bash
# Blob (file) — bundle written next to the file
echo "release notes" > notes.txt
cosign sign-blob --yes --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --identity-token "$(scripts/get-token.sh user)" --bundle notes.txt.sigstore.json notes.txt
cosign verify-blob --trusted-root "$SIGSTORE_TRUSTED_ROOT" --bundle notes.txt.sigstore.json \
  --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore notes.txt

# In-toto attestation (e.g. SBOM / provenance) attached to the image
echo '{"builder":"laptop","commit":"abc123"}' > predicate.json
cosign attest --yes --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --identity-token "$(scripts/get-token.sh user)" \
  --type https://example.com/build/v1 --predicate predicate.json "$IMAGE"
cosign verify-attestation --trusted-root "$SIGSTORE_TRUSTED_ROOT" --type https://example.com/build/v1 \
  --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore "$IMAGE" \
  | jq -r .payload | base64 -d | jq .predicate
```

All three (image, blob, attestation) were exercised by the integration test.

## 6. Trust via TUF instead of flags

Once `scripts/12-publish-tuf.sh` has run, any machine can bootstrap once and
then drop every `--trusted-root` / `--signing-config` flag:

```bash
cosign initialize --mirror https://tuf.sigstore.local --root out/tuf/root.json
cosign sign --yes --identity-token "$(scripts/get-token.sh ci)" "$IMAGE"
cosign verify --certificate-identity ci@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore "$IMAGE"
```

(`cosign initialize` writes to `~/.sigstore/root`; use a fresh `HOME` or
`TUF_ROOT=<dir>` to keep the private and any public trust separate.)

## 7. Show the Rekor log entries stored locally

```bash
scripts/11-inspect-rekor.sh 3
```

Sample output (from the integration test):

```
{ "treeSize": 2, "rootHash": "1c00256b…", "treeID": "7370287423267041459", ... }
────────────────────────────────────────────────────────────
logIndex       : 1
kind           : dsse/0.0.1
integratedTime : 2026-10-19T19:32:49Z
logID          : b7ed7e9681ffe3f3…        <- sha256 of YOUR Rekor public key
artifact hash  : sha256:38cd32bc…
  cert: issuer=O = Sigstore Offline Lab, OU = Code Signing, CN = Sigstore Offline Fulcio Intermediate CA
  cert: notBefore=Oct 19 19:32:49 2026 GMT
  cert: notAfter=Oct 19 19:42:49 2026 GMT   <- 10-minute certificate
  cert: X509v3 Subject Alternative Name: critical
  cert:     email:ci@sigstore.local
inclusion proof: 1 hashes, checkpoint signed by log
```

Raw API equivalents:

```bash
C="curl -fsS --cacert pki/tls/ca.crt"
$C https://rekor.sigstore.local/api/v1/log | jq                                  # tree size + signed checkpoint
$C "https://rekor.sigstore.local/api/v1/log/entries?logIndex=0" | jq             # one entry
$C https://rekor.sigstore.local/api/v1/index/retrieve -H 'Content-Type: application/json' \
   -d "{\"hash\":\"$DIGEST\"}" | jq                                             # search by artifact digest
$C "https://rekor.sigstore.local/api/v1/log/proof?firstSize=1&lastSize=2" | jq   # consistency proof
```

And at the storage layer — the entries are rows in **your** MySQL:

```bash
kubectl --context kind-sigstore -n trillian-system exec deploy/trillian-mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" trillian -e "
    SELECT TreeId, COUNT(*) AS leaves FROM SequencedLeafData GROUP BY TreeId;
    SELECT TreeId, TreeSize, FROM_UNIXTIME(TreeHeadTimestamp DIV 1000000000) AS ts
      FROM TreeHead ORDER BY TreeHeadTimestamp DESC LIMIT 4;"' 2>/dev/null
```

Two trees appear: the Rekor tree (signatures) and the CT log tree
(pre-certificates).

## 8. See it enforced

```bash
kubectl --context kind-sigstore create ns demo
kubectl --context kind-sigstore -n demo run signed   --image="$IMAGE"                                   # admitted
kubectl --context kind-sigstore -n demo run unsigned --image=registry.sigstore.local/demo/unsigned:v1     # denied by Kyverno
```
