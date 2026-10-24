# shellcheck shell=bash
# Shared helpers. Source me; do not execute me.
set -Eeuo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_ROOT
export PKI_DIR="${KIT_ROOT}/pki"
export OUT_DIR="${KIT_ROOT}/out"
export BUNDLE_DIR="${KIT_ROOT}/bundle"
export GEN_DIR="${KIT_ROOT}/.generated"

# shellcheck source=../config/env.sh
source "${KIT_ROOT}/config/env.sh"

# Generated secrets (passwords) live next to the PKI and are created by
# 03-generate-pki.sh. Scripts that need them call load_secrets.
SECRETS_FILE="${PKI_DIR}/secrets.env"

# Put bundled binaries (kind, kubectl, helm, crane, cosign) first on PATH.
if [[ -d "${BUNDLE_DIR}/bin" ]]; then
  export PATH="${BUNDLE_DIR}/bin:${PATH}"
fi

c_info=$'\033[1;34m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s !%s  %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s ✘%s  %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

trap 'die "failed at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command '$c' not found (see docs/02-installation-guide.md §1)"
  done
}

load_secrets() {
  [[ -f "$SECRETS_FILE" ]] || die "missing ${SECRETS_FILE}; run scripts/03-generate-pki.sh first"
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
}

# render <template> <output>
# Replaces ${VAR} placeholders with the value of EXPORTED variable VAR.
# Placeholders naming unset variables are left untouched (and reported), so
# literal '$' in templates is safe. Uses perl (present on every Linux/WSL).
render() {
  local tpl="$1" out="$2"
  require_cmd perl
  mkdir -p "$(dirname "$out")"
  perl -pe 's/\$\{([A-Z_][A-Z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$tpl" >"$out"
  if grep -qE '\$\{[A-Z_][A-Z0-9_]*\}' "$out"; then
    die "unrendered placeholders in $out: $(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$out" | sort -u | tr '\n' ' ')"
  fi
}

kctx() { echo "kind-${CLUSTER_NAME}"; }
k()    { kubectl --context "$(kctx)" "$@"; }
h()    { helm --kube-context "$(kctx)" "$@"; }

# chart_ref <name> <version> -> path to bundled .tgz (offline) or repo ref.
chart_ref() {
  local name="$1" version="$2" tgz
  tgz="$(ls "${BUNDLE_DIR}/charts/${name}-${version}.tgz" 2>/dev/null || true)"
  [[ -n "$tgz" ]] || die "chart ${name}-${version}.tgz not in ${BUNDLE_DIR}/charts (run 01-build-offline-bundle.sh while online)"
  echo "$tgz"
}

wait_rollout() { # ns kind/name [timeout]
  k -n "$1" rollout status "$2" --timeout="${3:-300s}"
}

wait_job() { # ns job [timeout]
  k -n "$1" wait --for=condition=complete "job/$2" --timeout="${3:-300s}"
}

ensure_ns() { k get ns "$1" >/dev/null 2>&1 || k create ns "$1"; }

# Copy the wildcard TLS cert into a namespace as secret "sigstore-tls".
ensure_tls_secret() {
  local ns="$1"
  ensure_ns "$ns"
  k -n "$ns" create secret tls sigstore-tls \
    --cert="${PKI_DIR}/tls/wildcard-fullchain.crt" --key="${PKI_DIR}/tls/wildcard.key" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}

# CA bundle the laptop's cosign/curl use to trust *.sigstore.local TLS.
tls_ca() { echo "${PKI_DIR}/tls/ca.crt"; }

# jwt_payload <token> -> decoded JSON claims (base64url, padding restored)
jwt_payload() {
  local p; p="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while (( ${#p} % 4 )); do p+="="; done
  base64 -d <<<"$p"
}

# pubkey_fp [pem-file]  (stdin when omitted or "-") -> sha256 of the DER
# SubjectPublicKeyInfo. Lets us compare keys regardless of PEM formatting.
pubkey_fp() {
  local der
  if [[ -z "${1:-}" || "$1" == "-" ]]; then
    der="$(openssl pkey -pubin -outform DER | openssl dgst -sha256 -r)"
  else
    der="$(openssl pkey -pubin -in "$1" -outform DER | openssl dgst -sha256 -r)"
  fi
  echo "${der%% *}"
}
