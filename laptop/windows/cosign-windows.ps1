<#
.SYNOPSIS
  Sign and verify with native cosign.exe on Windows against the private stack.
  (The supported path is the WSL shell + scripts/10-sign-and-verify.sh; this is
  for people who want to stay in PowerShell.)

  Prerequisites:
    * windows\Setup-Hosts.ps1 has been run (hosts + TLS root in Windows store;
      cosign.exe ignores SSL_CERT_FILE on Windows and uses the system store)
    * bundle\bin\windows\cosign.exe present (01-build-offline-bundle.sh with
      WITH_WINDOWS_CLI=1) and scripts/09-configure-cosign.sh has produced out\

.EXAMPLE
  .\windows\cosign-windows.ps1 -Image registry.sigstore.local/demo/hello@sha256:...
#>
param(
  [Parameter(Mandatory = $true)][string]$Image,
  [string]$Identity = "alice@sigstore.local",
  [string]$Issuer   = "https://keycloak.sigstore.local/realms/sigstore"
)
$ErrorActionPreference = "Stop"
$kit    = Resolve-Path (Join-Path $PSScriptRoot "..")
$cosign = Join-Path $kit "bundle\bin\windows\cosign.exe"
$root   = Join-Path $kit "out\trusted_root.json"
$sc     = Join-Path $kit "out\signing_config.json"
if ($Image -notmatch "@sha256:") { throw "Pass a digest reference (repo@sha256:...), never a tag." }

# Browser flow: opens Edge/Chrome at the Keycloak login page.
& $cosign sign --yes --signing-config $sc --trusted-root $root `
  --oidc-redirect-url "http://localhost:8765/auth/callback" $Image
if ($LASTEXITCODE -ne 0) { throw "signing failed" }

& $cosign verify --trusted-root $root `
  --certificate-identity $Identity --certificate-oidc-issuer $Issuer $Image
if ($LASTEXITCODE -ne 0) { throw "verification failed" }
Write-Host "Signed and verified $Image"
