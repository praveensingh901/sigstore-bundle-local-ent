#!/usr/bin/env bash
# =============================================================================
# test/compose/run.sh — end-to-end integration test WITHOUT Kubernetes.
#
# Brings up the same images/args the Helm charts use (docker-compose.yml),
# then runs the kit's own client scripts (09, 10, 11) inside a "toolbox"
# container attached ONLY to an internal Docker network with no route to the
# internet. A pass therefore proves: PKI + Keycloak realm + Fulcio OIDC/CACert
# config + CT log + Rekor file signer + cosign v3 trusted root/signing config
# work together fully offline.
#
#   test/compose/run.sh          # up + test
#   test/compose/run.sh down     # tear down (keeps pki/)
#
# Requires: docker (compose v2), bundle/bin/{cosign,crane,jq,createtree} (linux);
# optional bundle/bin/kyverno (policy tests) and bundle/bin/gitsign (commit signing).
# =============================================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../../scripts/lib.sh"
cd "$HERE" || exit 1
export COMPOSE_PROJECT_NAME=sigstore-offline-test
NET_OFFLINE=sigstore-offline-test_airgap

if [[ "${1:-}" == "down" ]]; then
  docker compose down -v --remove-orphans
  docker network rm "$NET_OFFLINE" 2>/dev/null || true
  rm -rf "${HERE}/.run"; ok "harness removed"; exit 0
fi

require_cmd docker
for b in cosign crane jq createtree; do
  [[ -x "${BUNDLE_DIR}/bin/$b" ]] || die "missing ${BUNDLE_DIR}/bin/$b"
done

"${KIT_ROOT}/scripts/03-generate-pki.sh"
load_secrets
# shellcheck disable=SC1091
source "${PKI_DIR}/meta.env"
export PKI_DIR MYSQL_ROOT_PASSWORD MYSQL_PASSWORD REKOR_SIGNER_PASSWORD FULCIO_CA_PASSWORD KEYCLOAK_ADMIN_PASSWORD

RUN="${HERE}/.run"; mkdir -p "$RUN"/{keycloak,fulcio,ctfe,secrets}
chmod 755 "$RUN" "$RUN"/*
# Kubernetes mounts Secret files 0644 for the (non-root) container user; mimic
# that with world-readable COPIES so pki/ itself stays 0600.
cp "${PKI_DIR}/rekor/rekor.key"           "$RUN/secrets/rekor.key"
cp "${PKI_DIR}/fulcio/intermediate.key"   "$RUN/secrets/fulcio-key.pem"
cp "${PKI_DIR}/fulcio/chain.pem"          "$RUN/secrets/fulcio-cert.pem"
cp "${PKI_DIR}/tls/wildcard.key"          "$RUN/secrets/tls.key"
chmod 644 "$RUN"/secrets/*

log "Rendering Keycloak realm + Fulcio config"
render "${KIT_ROOT}/config/keycloak/realm-sigstore.json.tpl" "$RUN/keycloak/realm-sigstore.json"
jq -n --arg iss "$OIDC_ISSUER" --arg cid "$OIDC_CLIENT_ID" --rawfile ca "$(tls_ca)" \
  '{OIDCIssuers: {($iss): {IssuerURL: $iss, ClientID: $cid, Type: "email", CACert: $ca}}}' \
  >"$RUN/fulcio/config.json"
chmod 644 "$RUN"/keycloak/* "$RUN"/fulcio/*

log "Starting Trillian (MySQL, createdb, log server, log signer)"
docker compose up -d mysql createdb logserver logsigner
for _ in $(seq 1 60); do
  REKOR_TREE_ID="$("${BUNDLE_DIR}/bin/createtree" --admin_server=127.0.0.1:18091 \
     --display_name=rekor-tree 2>/dev/null)" && break
  sleep 3
done
[[ -n "${REKOR_TREE_ID:-}" ]] || die "Trillian admin API never came up"
CT_TREE_ID="$("${BUNDLE_DIR}/bin/createtree" --admin_server=127.0.0.1:18091 --display_name=ctlog-tree)"
export REKOR_TREE_ID
ok "Trillian trees: rekor=${REKOR_TREE_ID} ctlog=${CT_TREE_ID}"

log "Writing CT front-end config (same proto createctconfig generates in k8s)"
cp "${PKI_DIR}/ctlog/ctlog.key" "$RUN/ctfe/privkey.pem"
cp "${PKI_DIR}/fulcio/chain.pem" "$RUN/ctfe/fulcio-0"
cat >"$RUN/ctfe/config" <<EOF
backends: {
  backend: {
    name: "trillian"
    backend_spec: "logserver:8091"
  }
}
log_configs: {
  config: {
    log_id: ${CT_TREE_ID}
    prefix: "${CTLOG_PREFIX}"
    roots_pem_file: "/ctfe-keys/fulcio-0"
    private_key: {
      [type.googleapis.com/keyspb.PEMKeyFile]: {
        path: "/ctfe-keys/privkey.pem"
        password: "${CTLOG_KEY_PASSWORD}"
      }
    }
    log_backend_name: "trillian"
    ext_key_usages: "CodeSigning"
  }
}
EOF
chmod 644 "$RUN"/ctfe/*

log "== 09-configure-cosign.sh + 12-publish-tuf.sh --build-only (no network needed) =="
"${KIT_ROOT}/scripts/09-configure-cosign.sh"
"${KIT_ROOT}/scripts/12-publish-tuf.sh" --build-only
export OUT_DIR

log "Starting Rekor, CT log, Fulcio, Keycloak, registry, TLS gateway (+TUF)"
docker compose up -d
# 12-publish-tuf.sh replaces out/tuf; a gateway left running from an earlier run
# would still serve the old (deleted) directory, so always recreate it.
docker compose up -d --force-recreate --no-deps gateway

# Air-gapped network: the toolbox can reach ONLY the TLS gateway.
docker network inspect "$NET_OFFLINE" >/dev/null 2>&1 || docker network create --internal "$NET_OFFLINE" >/dev/null
GW="$(docker compose ps -q gateway)"
docker network connect --alias keycloak.sigstore.local --alias fulcio.sigstore.local \
  --alias rekor.sigstore.local --alias registry.sigstore.local --alias tuf.sigstore.local \
  "$NET_OFFLINE" "$GW" 2>/dev/null || true

# Toolbox = a stand-in laptop: bash/curl/openssl/perl from the image; cosign,
# crane and jq from the kit's bundle/bin (lib.sh puts it first on PATH).
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-docker.io/library/buildpack-deps:bookworm-scm}"   # curl + git
tb() { docker run --rm --network "$NET_OFFLINE" -v "${KIT_ROOT}:/kit" -w /kit -e HOME=/tmp \
         -e AUTH -e IMAGE_REF -e EXPECT_IDENTITY "$TOOLBOX_IMAGE" bash -c "$*"; }

log "Proving the toolbox is air-gapped (public internet must be unreachable)"
if tb "curl -s -m 5 -o /dev/null https://rekor.sigstore.dev"; then die "toolbox has internet access"; fi
ok "No internet from toolbox"

log "Waiting for Keycloak / Fulcio / Rekor behind TLS"
READY=0
for _ in $(seq 1 90); do
  if tb "curl -fsS --cacert pki/tls/ca.crt -o /dev/null ${OIDC_ISSUER}/.well-known/openid-configuration \
      && curl -fsS --cacert pki/tls/ca.crt -o /dev/null ${FULCIO_URL}/api/v1/rootCert \
      && curl -fsS --cacert pki/tls/ca.crt -o /dev/null ${REKOR_URL}/api/v1/log" 2>/dev/null; then
    READY=1; break
  fi
  sleep 4
done
[[ $READY -eq 1 ]] || { docker compose ps; docker compose logs --tail 30 fulcio rekor keycloak; die "endpoints not ready"; }
ok "All endpoints answer over TLS"

log "Pushing demo image into the private registry"
docker image inspect "${DEMO_BASE_IMAGE}" >/dev/null 2>&1 \
  || docker image inspect "${DEMO_BASE_IMAGE#docker.io/library/}" >/dev/null 2>&1 \
  || die "load ${DEMO_BASE_IMAGE} first"
docker build -q -t 127.0.0.1:5001/demo/hello:v1 --build-arg BASE_IMAGE="${DEMO_BASE_IMAGE}" \
  "${KIT_ROOT}/examples/demo-app" >/dev/null
docker push -q 127.0.0.1:5001/demo/hello:v1 >/dev/null

log "== 10-sign-and-verify.sh (AUTH=password, user identity) =="
AUTH=password IMAGE_REF="${REGISTRY_HOST}/demo/hello:v1" tb scripts/10-sign-and-verify.sh
log "== 10-sign-and-verify.sh (AUTH=ci, machine identity) =="
AUTH=ci IMAGE_REF="${REGISTRY_HOST}/demo/hello:v1" tb scripts/10-sign-and-verify.sh
log "== 11-inspect-rekor.sh =="
tb scripts/11-inspect-rekor.sh 2

log "== TUF bootstrap: cosign initialize, then verify/attest/blob with NO trust flags =="
cat >"$RUN/tuf-client-test.sh" <<'TEST'
set -Eeuo pipefail
source scripts/lib.sh
export SSL_CERT_FILE=/kit/out/ca-bundle.pem
cosign initialize --mirror "$TUF_URL" --root out/tuf/root.json >/dev/null
IMG="$(cat out/last-signed-image)"; TOKEN="$(scripts/get-token.sh ci)"
cosign verify --certificate-identity "ci@${DOMAIN}" --certificate-oidc-issuer "$OIDC_ISSUER" "$IMG" >/dev/null
echo "  image signature verified"
echo provenance >/tmp/a.txt
cosign sign-blob --yes --identity-token "$TOKEN" --bundle /tmp/a.bundle /tmp/a.txt >/dev/null 2>&1
cosign verify-blob --bundle /tmp/a.bundle --certificate-identity "ci@${DOMAIN}" \
  --certificate-oidc-issuer "$OIDC_ISSUER" /tmp/a.txt >/dev/null 2>&1
echo "  blob signature verified"
echo '{"builder":"offline-ci"}' >/tmp/p.json
cosign attest --yes --identity-token "$TOKEN" --type https://example.com/ci-provenance/v1 \
  --predicate /tmp/p.json "$IMG" >/dev/null 2>&1
cosign verify-attestation --type https://example.com/ci-provenance/v1 --certificate-identity "ci@${DOMAIN}" \
  --certificate-oidc-issuer "$OIDC_ISSUER" "$IMG" >/dev/null 2>&1
echo "  in-toto attestation verified"
TEST
tb "bash test/compose/.run/tuf-client-test.sh"
ok "TUF-bootstrapped client works"

if [[ -x "${BUNDLE_DIR}/bin/kyverno" ]]; then
  log "== Kyverno ImageValidatingPolicy (13-deploy-policy.sh --render-only + kyverno CLI) =="
  "${KIT_ROOT}/scripts/13-deploy-policy.sh" --render-only >/dev/null
  SIGNED="$(cat "${OUT_DIR}/last-signed-image")"
  docker tag 127.0.0.1:5001/demo/hello:v1 127.0.0.1:5001/demo/unsigned:v1
  docker push -q 127.0.0.1:5001/demo/unsigned:v1 >/dev/null
  UNSIGNED="${REGISTRY_HOST}/demo/unsigned@${SIGNED#*@}"
  mkdir -p "${GEN_DIR}"
  cat >"${GEN_DIR}/kyverno-test-pods.yaml" <<PODS
apiVersion: v1
kind: Pod
metadata: {name: signed, namespace: demo}
spec: {containers: [{name: app, image: "${SIGNED}"}]}
---
apiVersion: v1
kind: Pod
metadata: {name: unsigned, namespace: demo}
spec: {containers: [{name: app, image: "${UNSIGNED}"}]}
PODS
  RES="$(tb "SSL_CERT_FILE=/kit/out/ca-bundle.pem bundle/bin/kyverno apply .generated/kyverno-verify-images.yaml --resource .generated/kyverno-test-pods.yaml 2>&1" || true)"
  echo "$RES" | grep -E "^policy|^pass" | sed 's/^/  /'
  echo "$RES" | grep -q "pass: 1, fail: 1" || die "Kyverno did not admit signed + deny unsigned"
  echo "$RES" | grep -q "Pod/unsigned failed" || die "unsigned image was not the one denied"
  ok "Kyverno: signed admitted, unsigned denied (trust from private TUF)"

  log "== Kyverno attestor shapes used by the enterprise policy pack =="
  # (a) ONE attestor with TWO identities: cosign v3 bundle verification accepts
  #     only one identity, so even the signed image must fail. This is why
  #     enterprise policies put one identity in each attestor.
  # (b) TWO attestors combined with || in CEL: the signed image passes.
  python3 - "${GEN_DIR}/kyverno-verify-images.yaml" "${GEN_DIR}" <<'PY'
import sys, copy, yaml
src, out = sys.argv[1], sys.argv[2]
pol = yaml.safe_load(open(src))
ident = pol["spec"]["attestors"][0]["cosign"]["keyless"]["identities"][0]
two = copy.deepcopy(pol); two["metadata"]["name"] = "two-identities-one-attestor"
two["spec"]["attestors"][0]["cosign"]["keyless"]["identities"] = [ident, {"issuer": ident["issuer"], "subject": "nobody@example.invalid"}]
yaml.safe_dump(two, open(f"{out}/kyverno-two-identities.yaml", "w"))
alt = copy.deepcopy(pol); alt["metadata"]["name"] = "two-attestors-or"
a1 = alt["spec"]["attestors"][0]; a2 = copy.deepcopy(a1)
a1["name"] = "nobody"; a1["cosign"]["keyless"]["identities"] = [{"issuer": ident["issuer"], "subject": "nobody@example.invalid"}]
a2["name"] = "people"
alt["spec"]["attestors"] = [a1, a2]
alt["spec"]["validations"] = [{"expression": "images.containers.all(image, verifyImageSignatures(image, [attestors.nobody]) > 0 || verifyImageSignatures(image, [attestors.people]) > 0)", "message": "not signed by an allowed identity"}]
yaml.safe_dump(alt, open(f"{out}/kyverno-two-attestors.yaml", "w"))
PY
  RES2="$(tb "SSL_CERT_FILE=/kit/out/ca-bundle.pem bundle/bin/kyverno apply .generated/kyverno-two-identities.yaml --resource .generated/kyverno-test-pods.yaml 2>&1" || true)"
  echo "$RES2" | grep -E "^pass" | sed 's/^/  two identities, one attestor: /'
  echo "$RES2" | grep -q "pass: 0" || die "a two-identity attestor unexpectedly verified a v3 bundle"
  RES3="$(tb "SSL_CERT_FILE=/kit/out/ca-bundle.pem bundle/bin/kyverno apply .generated/kyverno-two-attestors.yaml --resource .generated/kyverno-test-pods.yaml 2>&1" || true)"
  echo "$RES3" | grep -E "^pass" | sed 's/^/  two attestors with ||:        /'
  echo "$RES3" | grep -q "pass: 1, fail: 1" || die "two attestors combined with || did not admit the signed image"
  ok "Kyverno: one identity per attestor, alternatives with || (as in enterprise/policies)"
fi

if [[ -x "${BUNDLE_DIR}/bin/gitsign" ]]; then
  log "== gitsign: signed commits and tags against the private Sigstore =="
  tb "bash test/compose/gitsign-test.sh"
  ok "gitsign commit/tag signing and verification work offline"
fi
ok "END-TO-END OFFLINE TEST PASSED"
