# 11 — Test Report

What was actually executed while building this kit, with which versions, and
what was **not** executed. Re-run the automated parts any time with
`test/compose/run.sh`.

Date: 2026-10-19/20; Kyverno attestor and gitsign rows 2026-10-24. Host: Linux x86_64, Docker 29.8.2, OpenSSL 3.0.

## 1. Summary

| Area | How it was tested | Result |
|---|---|---|
| PKI generation (`03`) | ran from scratch; `openssl verify`, EKU/basicConstraints checks; keys loaded by real Fulcio, Rekor and ct_server | **PASS** |
| Keycloak realm + token claims | Keycloak 26.8.1 `start --import-realm`; password + client_credentials grants; decoded `iss`/`aud`/`email`/`email_verified` | **PASS** |
| Fulcio OIDC trust via `CACert` + fileca intermediate | Fulcio v1.9.0 (chart image digest) fetching Keycloak discovery over private TLS; `/api/v1/rootCert` = `pki/fulcio/chain.pem`; `/api/v2/configuration` lists the realm | **PASS** |
| CT log with our key | ct_server v0.7.33 using legacy-encrypted key + Fulcio chain; SCTs embedded and verified by cosign | **PASS** |
| Rekor file signer | rekor-server v1.5.4; served public key fingerprint = `pki/rekor/rekor.pub`; log ID = sha256(key) | **PASS** |
| Keyless sign + verify, human identity (`10`, AUTH=password) | cosign v3.1.3 with `--signing-config/--trusted-root`; verify + wrong-identity negative test | **PASS** |
| Keyless sign + verify, machine identity (`10`, AUTH=ci) | Keycloak `client_credentials` access token as `--identity-token` | **PASS** |
| Rekor inspection (`11`) | entries `dsse/0.0.1`, cert issuer = private intermediate, 10-min validity, SAN e-mail | **PASS** |
| TUF mirror (`12 --build-only`) + `cosign initialize` | repo built with scaffolding server v0.7.39; cosign verify/sign-blob/verify-blob/attest/verify-attestation with **no trust flags** | **PASS** |
| Kyverno ImageValidatingPolicy (`13 --render-only`) | Kyverno CLI v1.19.1 against the live registry + TUF: signed Pod passes, unsigned Pod fails; identity restricted to `bob@` → both fail | **PASS** |
| Kyverno attestor shapes (enterprise policies) | Kyverno CLI against the live registry: one attestor with two identities → `pass: 0` (cosign v3 bundles accept one identity); two attestors combined with `\|\|` → signed passes, unsigned fails | **PASS** |
| gitsign v0.18.0 (`14`, `gitsign-test.sh`) | `14-configure-gitsign.sh` sets up git with trust from the private TUF mirror (a decoy public-good TUF cache that sorts first is ignored); commit + annotated tag signed against private Fulcio/Rekor/CT; `gitsign verify` prints all three `Validated … true` lines; `verify-tag`; `git verify-commit` verifies signature + Rekor and warns that it does not check certificate claims; wrong identity rejected; `matchCommitter` refuses a mismatched `user.email`; no private trust → rejected | **PASS** |
| Gatekeeper constraint | `gator test` v3.23.1: off-registry/tag-only Pod → 2 violations; digest-pinned private image → none | **PASS** |
| Air-gap | all client steps in a Docker network created with `--internal`; test asserts `https://rekor.sigstore.dev` unreachable first | **PASS** |
| DR: MySQL dump → DROP DATABASE → restore | Rekor `treeSize`/`rootHash` identical before/after; pre-incident signature verifies; new entry appended; consistency proof 4→5 served | **PASS** |
| Trusted-root rotation command (docs/05 §6.2) | `cosign trusted-root create` with two `--fulcio` (one `end-time`) | **PASS** |
| Helm values | `helm template` of all 6 charts at pinned versions with the kit's values (Traefik values validated against the chart's JSON schema) | **PASS** |
| Plain manifests | `kubeconform -strict` (registry, Keycloak, TUF: 14 objects) | **PASS** |
| CoreDNS zone | CoreDNS v1.12.1 container with the rendered block: arbitrary `*.sigstore.local` → `10.96.100.100` | **PASS** |
| Offline mirror layout | registry:2 + `crane copy`: multi-arch index digests preserved; manifests served at `/v2/<registry>/<repo>/manifests/<digest>` (the path containerd uses with `override_path`) | **PASS** |
| Bundle builder (`01`) + loader checks (`02`) | executed end-to-end on a scratch copy: 5.1 GB, 25/25 images resolvable by digest through the mirror path, checksums + `docker load` OK (§3) | **PASS** |
| Shell scripts | `shellcheck -S warning` — no errors | **PASS** |

## 2. Not executed here (and why)

| Item | Status | Why / mitigation |
|---|---|---|
| kind cluster bring-up (`04`–`08`, `12`/`13` deploy parts) on Kubernetes | **not run** | the build sandbox cannot run nested containers (kind/k3s pod sandboxes fail with `oom_score_adj` permission errors). Mitigations: every component was run with the **same images and arguments the charts render** in the Docker harness; all Helm values render against the real charts; manifests pass kubeconform. First run on your laptop: use `install-all.sh` and `verify-stack.sh`, and see docs/08 if a step fails. |
| containerd `hosts.toml` mirror redirect inside kind | not run | layout verified at the registry API level; configuration follows kind's documented `config_path` mechanism (node images ≥ v0.27). Fallback if needed: docs/08 "Bundle / images". |
| Browser and device-code login | not run (no browser) | the token path is identical to the tested password/CI grants; redirect URI is registered exactly |
| Windows PowerShell scripts | not run | standard cmdlets (`Import-Certificate`, hosts edit); review before use |
| Sigstore policy-controller manifests | reference only | marked as such in the file |
| Production KMS/HSM examples | reference only | require your cloud/HSM |

## 3. Bundle build

Recorded from `DOCKERHUB_MIRROR=mirror.gcr.io WITH_WINDOWS_CLI=1 scripts/01-build-offline-bundle.sh`:

```
 ✔  tools: cosign crane helm jq kind kubectl windows(cosign.exe crane.exe)
 ✔  charts: ctlog-0.2.69 fulcio-2.11.4 kyverno-3.9.1 rekor-1.8.7 traefik-42.0.0 trillian-0.4.0
 ✔  25 images: see bundle/images.txt
 ✔  mirror populated: 4.2G            (full multi-arch indexes, digests preserved)
 ✔  host images: 395M                 (kindest/node:v1.37.0, registry:2.8.3, TUF server, busybox)
 ✔  Offline bundle complete: 5.1G
```

Offline-side checks on that bundle:

* `sha256sum -c SHA256SUMS` → OK
* `docker load -i bundle/images/host-images.tar` → 4 images loaded under the
  tags `config/env.sh` expects
* registry:2 serving `bundle/mirror`: **25/25** images resolvable **by their
  pinned digest** at `/v2/<registry>/<repo>/manifests/<digest|tag>` — the exact
  request containerd makes through `hosts.toml` with `override_path`.

Two defects found and fixed by this run: `bundle/bin` was not on `PATH` on the
very first run, and a Docker Hub mirror missing a rare-platform blob aborted a
copy (now falls back to the origin registry).

The 25 images:

```
docker.io/busybox@sha256:fd7dc986…           ghcr.io/sigstore/scaffolding/createtree:v0.7.33@sha256:4c845ced…
docker.io/curlimages/curl:8.17.0@sha256:935d…  ghcr.io/sigstore/scaffolding/createtree@sha256:4c845ced…
docker.io/curlimages/curl@sha256:935d9100…     ghcr.io/sigstore/scaffolding/ct_server:v0.7.33@sha256:24293fa1…
docker.io/library/registry:2.8.3              ghcr.io/sigstore/scaffolding/server@sha256:b5b67a42…
docker.io/redis@sha256:148bb541…               ghcr.io/sigstore/scaffolding/trillian_log_server@sha256:32ee491f…
docker.io/traefik:v3.7.14                      ghcr.io/sigstore/scaffolding/trillian_log_signer@sha256:3d015230…
gcr.io/trillian-opensource-ci/db_server@sha256:2a685a38…   quay.io/keycloak/keycloak:26.8.1
ghcr.io/kyverno/readiness-checker:v1.19.1      reg.kyverno.io/kyverno/{kyverno,kyvernopre,background-controller,
ghcr.io/sigstore/fulcio:v1.9.0@sha256:2de0226c…   cleanup-controller,reports-controller,kyverno-cli}:v1.19.1
ghcr.io/sigstore/rekor/rekor-server:v1.5.4@sha256:100d793d…
ghcr.io/sigstore/scaffolding/createctconfig:v0.7.33@sha256:e591f98e…
ghcr.io/sigstore/scaffolding/createdb@sha256:16673c10…
```

## 4. Reproducing the integration test

```bash
# requires docker, bundle/bin/{cosign,crane,jq,createtree} (+ optional kyverno CLI)
test/compose/run.sh          # ~5 min; ends with "END-TO-END OFFLINE TEST PASSED"
test/compose/run.sh down
```

`createtree` (Trillian admin CLI, used only by the harness) can be built with
`CGO_ENABLED=0 go install github.com/google/trillian/cmd/createtree@v1.7.2`;
the Kyverno CLI is the `kyverno-cli_v1.19.1_linux_x86_64.tar.gz` release asset.
