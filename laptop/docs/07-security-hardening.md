# 07 — Security Hardening Guide

The laptop kit favours clarity. This guide lists every shortcut it takes and
what to do instead. Items are ordered by impact.

## 1. Lab shortcuts and their hardened replacement

| # | Lab behaviour | Risk | Harden by |
|---|---|---|---|
| 1 | Fulcio root key generated on the laptop (`pki/fulcio/root.key`) | root compromise = re-root everything | generate root on an offline machine/HSM in a recorded ceremony; move it off the laptop **immediately** after issuing the intermediate |
| 2 | All passwords in `pki/secrets.env` next to the keys | file theft decrypts all keys | keep passwords in a vault (HashiCorp Vault, KeePassXC, HSM PINs); split root password k-of-n |
| 3 | Intermediate / Rekor keys in Kubernetes Secrets | etcd/backup exposure | KMS/HSM: Fulcio `kmsca`/`pkcs11ca`, Rekor `--rekor_server.signer=<kms-uri>`; enable etcd encryption-at-rest; External Secrets |
| 4 | Rekor signer password passed as a container argument | visible in `kubectl get pod -o yaml` | KMS signer (no password), or restrict `get pods` RBAC in `rekor-system` |
| 5 | Keycloak `dev-file` (H2), single replica | data loss, no HA | PostgreSQL HA, 2+ replicas, `KC_CACHE=ispn` |
| 6 | Demo user with password grant enabled (`directAccessGrantsEnabled`) | password-spraying path to signing certs | disable direct access grants on `sigstore`; humans use browser/device flow with MFA |
| 7 | One shared CI identity `ci@sigstore.local` | any pipeline can sign as "CI" | one confidential client per repo/team; policies pin exact identities |
| 8 | Registry without authentication | anyone on the laptop can push | Harbor/registry token auth, robot accounts, immutable tags, push only from CI |
| 9 | Kyverno identity regex `.*@sigstore.local` | any realm user may ship anything | per-namespace exact subjects (docs/04 §5.1) |
| 10 | TUF built by scaffolding with throw-away keys, 6-month expiry | no root rotation chain | TUF with persistent offline root keys (k-of-n), online timestamp key only |
| 11 | TLS wildcard for all services | one key for all hosts | per-service certs from cert-manager + corporate CA |
| 12 | Mirror registry plain HTTP | local tampering of images on the laptop | digest pinning already prevents silent substitution; bind to 127.0.0.1 (done); in prod use an authenticated pull-through cache |

## 2. Key custody matrix (production)

| Key | Where | Who can use | Ceremony |
|---|---|---|---|
| Fulcio root | offline HSM or encrypted media in safe | 2-of-3 security officers | yes, recorded |
| Fulcio intermediate | cloud KMS / HSM, non-exportable | Fulcio service identity only | issuance recorded |
| Rekor signer | KMS / HSM | Rekor service identity | yes |
| CT log key | secret manager → ctfe (legacy PEM) or tiles CT with KMS | ctfe only | yes |
| TUF root (k-of-n) | offline hardware tokens | security officers | yes |
| TUF targets/snapshot/timestamp | online KMS (timestamp), offline (targets) | publishing pipeline | — |
| TLS | cert-manager / corporate CA | ingress | standard |

## 3. Certificate profiles (what the kit enforces)

* Fulcio root: `CA:TRUE, pathlen:1`, `keyCertSign, cRLSign`, P-384, 10 y.
* Fulcio intermediate: `CA:TRUE, pathlen:0`, `keyCertSign, cRLSign`,
  **EKU codeSigning** (required by Fulcio for chained CAs), P-384, 5 y.
* Leaf certs (Fulcio-issued): 10-minute validity, SAN = identity, issuer
  extension (OID 1.3.6.1.4.1.57264.1.8) = OIDC issuer, embedded SCT.
* TLS server: `CA:FALSE`, `digitalSignature`, EKU serverAuth, 397 days.

## 4. Kubernetes hardening for the Sigstore namespaces

```bash
# Pod Security Admission
kubectl label ns fulcio-system rekor-system ctlog-system trillian-system tuf-system \
  pod-security.kubernetes.io/enforce=restricted --overwrite
# (trillian-mysql needs "baseline" if your MySQL image runs as root)
```

NetworkPolicies (default-deny, then allow only the flows in the architecture):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: trillian-system }
spec: { podSelector: {}, policyTypes: [Ingress] }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: logserver-from-rekor-ctlog, namespace: trillian-system }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: trillian-logserver } }
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: rekor-system } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ctlog-system } }
      ports: [{ port: 8091 }, { port: 8090 }]
```

Repeat for: MySQL ← log server/signer only; CT log ← Fulcio only; Fulcio/Rekor
← Traefik only; Redis ← Rekor only. (kind's default CNI, kindnet, does **not**
enforce NetworkPolicy; use Calico/Cilium in production.)

RBAC: only the platform team may `get secrets` / `exec` in `fulcio-system`,
`rekor-system`, `ctlog-system`, `trillian-system`. Audit-log `secrets` reads.

## 5. OIDC hardening

* Require MFA in the realm (Keycloak *Authentication → Flows → OTP/WebAuthn*)
  or at the upstream IdP.
* Disable `directAccessGrantsEnabled` and remove `urn:ietf:wg:oauth:2.0:oob`
  and the `http://localhost/*` wildcards once everyone uses
  `--oidc-redirect-url http://localhost:8765/auth/callback`.
* Short tokens (5 min) — already set. Fulcio only needs the token once.
* Never mark `emailVerified` true for self-registered users;
  `registrationAllowed: false` (already set).
* Rotate `sigstore-ci` secrets quarterly; prefer CI-native OIDC (GHES/GitLab)
  where available — no stored secret at all.

## 6. Admission policy hardening

* `failurePolicy: Fail` (set) — an unreachable verifier must not mean "allow".
* Match **all** registries you run from, and deny images not from approved ones
  (Gatekeeper constraint in `config/policies/gatekeeper/`).
* Require digests (`verifyDigest`, Gatekeeper digest rule).
* Add attestation requirements (provenance/SBOM) per environment.
* Monitor `PolicyReport`s and webhook latency; alert on bypass labels.

## 7. Supply-chain of the kit itself

* Every image in the charts is pinned by **digest**; `crane copy` preserves it.
* `bundle/SHA256SUMS` is verified before load (`02`).
* Tool binaries come from upstream release URLs pinned in `config/env.sh`;
  verify them on the online machine (e.g. `cosign verify-blob` of the cosign
  release, checksums for kind/helm/crane) before building the bundle.
* Treat `bundle/` like installation media: transfer through your approved
  channel, scan it, keep a hash of the transferred archive.

## 8. Laptop hygiene

* Full-disk encryption on.
* `pki/` is `0700`/`0600`; keep the kit inside the WSL filesystem or an
  encrypted volume, not on removable media.
* `scripts/99-teardown.sh --purge` when the lab is no longer needed — after a backup.
