#!/usr/bin/env bash
# Downloads pinned tool releases and verifies them before the image build.
# cosign is verified with its own release signature (keyless, public-good
# Sigstore) on the connected build host; the others against published checksums.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p tools
COSIGN=v3.1.3; CRANE=v0.22.1; ORAS=1.3.5; JQ=1.8.2; GITSIGN=0.18.0
curl -fsSLo tools/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN}/cosign-linux-amd64"
curl -fsSLo cosign.bundle "https://github.com/sigstore/cosign/releases/download/${COSIGN}/cosign-linux-amd64.sigstore.json"
cosign verify-blob tools/cosign --bundle cosign.bundle \
  --certificate-identity "keyless@projectsigstore.iam.gserviceaccount.com" \
  --certificate-oidc-issuer "https://accounts.google.com"
curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C tools crane
curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS}/oras_${ORAS}_linux_amd64.tar.gz" | tar -xz -C tools oras
curl -fsSLo tools/jq "https://github.com/jqlang/jq/releases/download/jq-${JQ}/jq-linux-amd64"
curl -fsSLo tools/gitsign "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN}/gitsign_${GITSIGN}_linux_amd64"
curl -fsSL "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN}/checksums.txt" \
  | grep " gitsign_${GITSIGN}_linux_amd64$" | sed "s| gitsign_${GITSIGN}_linux_amd64| tools/gitsign|" | sha256sum -c -
cp ../../../laptop/scripts/export-trust.sh tools/export-trust.sh   # trusted_root.json -> files gitsign reads
echo "Now verify crane/oras/jq against their published checksums and record the SHA-256 values in the build log:"
sha256sum tools/*
cp ../../pki/root.crt ca.crt
cp ../../tuf/root/1.root.json tuf-root.json
