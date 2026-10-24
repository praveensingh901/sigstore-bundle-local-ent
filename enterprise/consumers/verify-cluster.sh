#!/usr/bin/env bash
# verify-cluster.sh <signed-image@digest> <unsigned-image@digest> <tuf-url> [namespace]
# Proves a consumer cluster enforces signatures (05-consumer-clusters.md §5).
# Run with a kube context for the cluster; exit 0 only if all four checks pass.
# Use it after install, after Kyverno upgrades, and from cluster monitoring.
set -euo pipefail
SIGNED="${1:?signed image by digest}"; UNSIGNED="${2:?unsigned image by digest}"
TUF="${3:?TUF replica URL, e.g. https://tuf.sigstore.corp.example}"; NS="${4:-sigstore-canary}"
MIN_DAYS="${MIN_DAYS:-3}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

for p in allowed-registries protect-sigstore-namespace-labels; do
  [[ "$(kubectl get validatingpolicy "$p" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" == "true" ]] \
    || fail "ValidatingPolicy $p not ready"
done
for p in baseline-signed-by-central-workflow third-party-imported-only staff-signed-optin; do
  [[ "$(kubectl get imagevalidatingpolicy "$p" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" == "true" ]] \
    || fail "ImageValidatingPolicy $p not ready"
done
pass "policies ready"

MODE="$(kubectl get imagevalidatingpolicy baseline-signed-by-central-workflow -o jsonpath='{.spec.validationActions[*]}')"
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS missing (create it without the break-glass label)"

kubectl -n "$NS" run sigstore-ok --image="$SIGNED" --restart=Never --dry-run=server -o name >/dev/null \
  || fail "signed image was rejected: $SIGNED"
pass "signed image admitted"

if [[ "$MODE" == *Deny* ]]; then
  if kubectl -n "$NS" run sigstore-bad --image="$UNSIGNED" --restart=Never --dry-run=server -o name >/dev/null 2>&1; then
    fail "unsigned image was ADMITTED: $UNSIGNED"
  fi
  pass "unsigned image denied"
else
  echo "info policy in ${MODE:-unknown} mode: denial check skipped; see PolicyReports in $NS"
fi

EXP="$(curl -fsS "${TUF%/}/timestamp.json" | jq -r .signed.expires)" || fail "cannot read ${TUF}/timestamp.json"
LEFT=$(( ( $(date -d "$EXP" +%s) - $(date +%s) ) / 86400 ))
(( LEFT >= MIN_DAYS )) || fail "TUF timestamp expires in ${LEFT} days (< ${MIN_DAYS})"
pass "TUF timestamp valid for ${LEFT} more days"
echo "PASS cluster $(kubectl config current-context)"
