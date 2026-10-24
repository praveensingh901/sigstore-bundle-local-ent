#!/usr/bin/env bash
# =============================================================================
# install-all.sh — deploy the complete offline stack in one go (≈10–15 min).
#   Prerequisite: bundle/ built online (01-build-offline-bundle.sh) and the
#   laptop hosts file prepared (scripts/setup-hosts.sh or windows\Setup-Hosts.ps1).
#
#   AUTH=browser scripts/install-all.sh   # sign the demo with a browser login
#   (default AUTH=password: fully unattended, uses the demo user's password)
# =============================================================================
source "$(dirname "$0")/lib.sh"
S="${KIT_ROOT}/scripts"
export AUTH="${AUTH:-password}"
step() { echo; printf '\033[1;35m######## %s ########\033[0m\n' "$*"; }

step "00 prerequisites";        "$S/00-check-prereqs.sh"
step "02 load offline bundle";  "$S/02-load-offline-bundle.sh"
step "03 generate PKI";         "$S/03-generate-pki.sh"
step "04 create kind cluster";  "$S/04-create-cluster.sh"
step "05 ingress + DNS";        "$S/05-deploy-ingress.sh"
step "06 private registry";     "$S/06-deploy-registry.sh"
step "07 Keycloak (OIDC)";      "$S/07-deploy-keycloak.sh"
step "08 Trillian/Rekor/Fulcio/CTLog"; "$S/08-deploy-sigstore.sh"
step "09 cosign trust";         "$S/09-configure-cosign.sh"
step "10 sign + verify demo";   "$S/10-sign-and-verify.sh"
step "11 inspect Rekor";        "$S/11-inspect-rekor.sh" 1
step "12 TUF mirror";           "$S/12-publish-tuf.sh"
step "13 admission policy";     "$S/13-deploy-policy.sh"
step "verify";                  "$S/verify-stack.sh"
echo
ok "Private Sigstore is running. Start with docs/00-getting-started.md §4."
