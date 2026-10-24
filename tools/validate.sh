#!/usr/bin/env bash
# tools/validate.sh — static validation of everything under enterprise/.
# Used by CI (.github/workflows/validate.yml) and locally. Needs: helm,
# kustomize, kubeconform, kyverno, terraform, tflint, checkov, python3+PyYAML.
#   CHARTS_DIR=<dir with unpacked charts>  skip downloading (offline)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
WORK="${WORK:-$(mktemp -d)}"; R="$WORK/render"; SCH="$WORK/schemas"; rm -rf "$R" "$SCH" "$WORK/crds"; mkdir -p "$R" "$SCH" "$WORK/crds"
CHARTS_DIR="${CHARTS_DIR:-$WORK/charts}"
log() { printf '\n== %s\n' "$*"; }

# ---- 1. charts (pinned) -------------------------------------------------------
declare -A CHART=(
  [fulcio]="sigstore 2.11.4" [rekor]="sigstore 1.8.7" [ctlog]="sigstore 0.2.69"
  [trillian]="sigstore 0.4.1" [tsa]="sigstore 2.1.5" [kyverno]="kyverno 3.9.2"
  [cert-manager]="jetstack v1.21.3" [external-secrets]="external-secrets 2.14.0"
  [aws-privateca-issuer]="awspca v1.11.1" [aws-load-balancer-controller]="eks 3.6.1"
  [argo-cd]="argo 10.11.1")
if [[ ! -d "$CHARTS_DIR/fulcio" ]]; then
  log "pull charts"
  helm repo add sigstore https://sigstore.github.io/helm-charts >/dev/null
  helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null
  helm repo add jetstack https://charts.jetstack.io >/dev/null
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null
  helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer >/dev/null
  helm repo add eks https://aws.github.io/eks-charts >/dev/null
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update >/dev/null
  mkdir -p "$CHARTS_DIR"
  for c in "${!CHART[@]}"; do read -r repo ver <<<"${CHART[$c]}"
    helm pull "$repo/$c" --version "$ver" --untar --untardir "$CHARTS_DIR"; done
fi

# ---- 2. render ------------------------------------------------------------------
log "helm template (platform, prod and dr)"
for env in prod dr; do
  for c in trillian rekor ctlog fulcio tsa aws-load-balancer-controller; do
    f=(-f "enterprise/helm/values/common/$c.yaml")
    [[ $env == prod || $c != aws-load-balancer-controller ]] && f+=(-f "enterprise/helm/values/prod/$c.yaml")
    [[ $env == dr ]] && f+=(-f "enterprise/helm/values/dr/$c.yaml")
    helm template "$c" "$CHARTS_DIR/$c" -n "$c" "${f[@]}" > "$R/$env-$c.yaml"
  done
done
for c in cert-manager external-secrets aws-privateca-issuer; do
  helm template "$c" "$CHARTS_DIR/$c" -n "$c" -f "enterprise/helm/values/common/$c.yaml" > "$R/$c.yaml"; done
for p in eks aks openshift onprem; do
  helm template kyverno "$CHARTS_DIR/kyverno" -n kyverno -f enterprise/helm/values/common/kyverno.yaml \
    -f "enterprise/consumers/$p/kyverno-values.yaml" > "$R/kyverno-$p.yaml"
  kustomize build "enterprise/consumers/$p" > "$R/policies-$p.yaml"
done
for o in prod/platform prod/services dr/platform dr/services; do
  kustomize build "enterprise/helm/manifests/overlays/$o" > "$R/manifests-${o/\//-}.yaml"; done
kustomize build enterprise/vendor/keycloak-operator > "$R/keycloak-operator.yaml"

# Guard: values that must land (01-architecture.md §4)
grep -q -- '--election_system=k8s' "$R/prod-trillian.yaml"
grep -q -- '--force_master=false' "$R/prod-trillian.yaml"
grep -q -- '--search_index.storage_provider=mysql' "$R/prod-rekor.yaml"
! grep -q -- '--enable_attestation_storage' "$R/prod-rekor.yaml"
! grep -q 'kind: Deployment' <(grep -A3 'name: rekor-redis' "$R/prod-rekor.yaml")
grep -q -- '--ca=kmsca' "$R/prod-fulcio.yaml"
grep -q -- '--timestamp-signer=kms' "$R/prod-tsa.yaml"
echo "required settings present"

# ---- 3. schemas + kubeconform ---------------------------------------------------------
log "CRD schemas"
helm template k "$CHARTS_DIR/kyverno" -n kyverno > "$WORK/crds/kyverno.yaml"
helm template k "$CHARTS_DIR/cert-manager" -n cm --set crds.enabled=true > "$WORK/crds/cert-manager.yaml"
helm template k "$CHARTS_DIR/external-secrets" -n es --set installCRDs=true > "$WORK/crds/eso.yaml"
cp "$CHARTS_DIR"/aws-privateca-issuer/crds/*.yaml "$CHARTS_DIR"/aws-load-balancer-controller/crds/*.yaml "$WORK/crds/" 2>/dev/null || true
helm template a "$CHARTS_DIR/argo-cd" -n argocd --set crds.install=true \
  --show-only templates/crds/crd-application.yaml --show-only templates/crds/crd-applicationset.yaml \
  --show-only templates/crds/crd-appproject.yaml > "$WORK/crds/argocd.yaml"
cp enterprise/vendor/keycloak-operator/*.k8s.keycloak.org-v1.yml "$WORK/crds/"
cp enterprise/vendor/openshift/*.crd.yaml "$WORK/crds/"
python3 tools/crd-schemas.py "$SCH" "$WORK"/crds/*.y*ml
log "kubeconform (strict)"
kubeconform -kubernetes-version 1.34.0 -strict -summary -skip CustomResourceDefinition,Kustomization \
  -schema-location default -schema-location "$SCH/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$R" enterprise/helm/manifests/platform enterprise/helm/manifests/keycloak enterprise/helm/manifests/tuf \
  enterprise/helm/manifests/monitor enterprise/policies/kyverno/teams enterprise/policies/openshift enterprise/gitops

# ---- 4. Kyverno CLI behaviour tests ----------------------------------------------------
log "kyverno CLI tests"
kyverno test enterprise/policies/tests

# ---- 5. Terraform -----------------------------------------------------------------------
log "terraform"
( cd enterprise/terraform
  terraform fmt -check -recursive
  for d in modules/private-ca modules/platform environments/*; do
    ( cd "$d" && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color ); done
  tflint --init --config "$PWD/.tflint.hcl" >/dev/null && tflint --recursive --config "$PWD/.tflint.hcl"
  checkov -d . --config-file .checkov.yaml --quiet --compact
  rm -rf modules/*/.terraform environments/*/.terraform )

log "ALL CHECKS PASSED"
