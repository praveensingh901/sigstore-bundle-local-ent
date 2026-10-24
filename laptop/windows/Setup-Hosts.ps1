<#
.SYNOPSIS
  Windows side of the sigstore-offline lab. Run in an *Administrator* PowerShell.

  1. Adds "127.0.0.1 keycloak/fulcio/rekor/registry/tuf.sigstore.local" to
     C:\Windows\System32\drivers\etc\hosts  (WSL2 copies this into /etc/hosts
     at start-up, so both Windows browsers and the WSL shell resolve the names)
  2. Imports the lab TLS root (pki\tls\ca.crt) into
     Cert:\LocalMachine\Root  so Edge/Chrome (Keycloak login page),
     cosign.exe and Docker Desktop trust https://*.sigstore.local

.EXAMPLE
  # from the kit folder, e.g. E:\cosign\full-installation\sigstore-offline
  powershell -ExecutionPolicy Bypass -File .\windows\Setup-Hosts.ps1
  powershell -ExecutionPolicy Bypass -File .\windows\Setup-Hosts.ps1 -Remove
#>
[CmdletBinding()]
param(
  [string]$Domain = "sigstore.local",
  [string]$CaPath = (Join-Path $PSScriptRoot "..\pki\tls\ca.crt"),
  [switch]$Remove
)
$ErrorActionPreference = "Stop"
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this script from an Administrator PowerShell."
}

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$marker    = "# sigstore-offline"
$names     = @("keycloak","fulcio","rekor","registry","tuf") | ForEach-Object { "$_.$Domain" }
$line      = "127.0.0.1 " + ($names -join " ") + " $marker"

$content = Get-Content $hostsFile | Where-Object { $_ -notmatch [regex]::Escape($marker) }
if (-not $Remove) { $content += $line }
Set-Content -Path $hostsFile -Value $content -Encoding ASCII
Write-Host ("hosts: " + ($(if ($Remove) {"entry removed"} else {$line})))

$subject = "CN=Sigstore Offline TLS Root CA, OU=TLS, O=Sigstore Offline Lab"
if ($Remove) {
  Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq $subject } | Remove-Item
  Write-Host "TLS root removed from LocalMachine\Root"
} else {
  if (-not (Test-Path $CaPath)) { throw "CA not found at $CaPath - run scripts/03-generate-pki.sh in WSL first." }
  Import-Certificate -FilePath $CaPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Write-Host "TLS root imported into LocalMachine\Root ($CaPath)"
}

ipconfig /flushdns | Out-Null
Write-Host ""
Write-Host "Next:"
Write-Host "  * Restart Docker Desktop (so its engine trusts the new root)."
Write-Host "  * In PowerShell:  wsl --shutdown   (WSL regenerates /etc/hosts on next start)."
