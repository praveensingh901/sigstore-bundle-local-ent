#!/usr/bin/env bash
# enterprise/tuf/test.sh — offline end-to-end test of tufctl.py with file keys.
# Builds a repository (3 custodian keys, threshold 2, one online key), checks
# that thresholds are enforced, publishes, runs a TUF client update, checks
# that a tampered target is rejected and, if cosign is on PATH, that
# `cosign initialize` accepts the repository.
# Needs: python3 with tuf>=6 and securesystemslib[crypto], openssl. Optional: cosign.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; trap '[[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null; rm -rf "$W"' EXIT
P=(python3 -I "$HERE/tufctl.py"); cd "$W"; mkdir keys
for k in c1 c2 c3 online; do
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "keys/$k.key" 2>/dev/null
  openssl pkey -in "keys/$k.key" -pubout -out "keys/$k.pub"
done
echo '{"mediaType":"application/vnd.dev.sigstore.trustedroot+json;version=0.1"}' > trusted_root.json
echo '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json"}' > signing_config.v0.2.json

"${P[@]}" init --repo repo --root-key keys/c1.pub --root-key keys/c2.pub --root-key keys/c3.pub --online-pub keys/online.pub
"${P[@]}" add-target --repo repo trusted_root.json signing_config.v0.2.json
"${P[@]}" sign --repo repo --role root --signer file2:keys/c1.key
if "${P[@]}" refresh --repo repo --online-signer file2:keys/online.key 2>/dev/null; then
  echo "FAIL: published with 1 of 2 root signatures"; exit 1; fi
echo "ok   refused to publish below threshold"
if "${P[@]}" sign --repo repo --role root --signer file2:keys/online.key 2>/dev/null; then
  echo "FAIL: online key accepted as a root key"; exit 1; fi
echo "ok   online key cannot sign root"
"${P[@]}" sign --repo repo --role root --signer file2:keys/c2.key
"${P[@]}" sign --repo repo --role targets --signer file2:keys/c1.key
"${P[@]}" sign --repo repo --role targets --signer file2:keys/c3.key
"${P[@]}" refresh --repo repo --online-signer file2:keys/online.key
"${P[@]}" verify --repo repo --root repo/publish/1.root.json

# Root rotation: replace custodian 3 with custodian 4. The new root must be
# signed by 2 of the NEW keys and 2 of the OLD keys.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out keys/c4.key 2>/dev/null
openssl pkey -in keys/c4.key -pubout -out keys/c4.pub
"${P[@]}" root-update --repo repo --remove-root-key keys/c3.pub --add-root-key keys/c4.pub
"${P[@]}" sign --repo repo --role root --signer file2:keys/c4.key
"${P[@]}" sign --repo repo --role root --signer file2:keys/c3.key      # old key co-signs
if "${P[@]}" refresh --repo repo --online-signer file2:keys/online.key 2>/dev/null; then
  echo "FAIL: new root published with 1 of 2 new-key signatures"; exit 1; fi
echo "ok   new root refused until both thresholds are met"
"${P[@]}" sign --repo repo --role root --signer file2:keys/c1.key
"${P[@]}" sign --repo repo --role targets --signer file2:keys/c1.key
"${P[@]}" sign --repo repo --role targets --signer file2:keys/c4.key
if "${P[@]}" sign --repo repo --role targets --signer file2:keys/c3.key 2>/dev/null; then
  echo "FAIL: removed key accepted for targets"; exit 1; fi
echo "ok   removed custodian key cannot sign targets"
"${P[@]}" refresh --repo repo --online-signer file2:keys/online.key
"${P[@]}" verify --repo repo --root repo/publish/1.root.json      # client walks 1 -> 2
test -s repo/publish/2.root.json && echo "ok   client pinned to root v1 updated to root v2"

f="$(ls repo/publish/targets/*.trusted_root.json)"; cp "$f" orig; echo " " >> "$f"
if "${P[@]}" verify --repo repo --root repo/publish/1.root.json 2>/dev/null; then
  echo "FAIL: tampered target accepted"; exit 1; fi
cp orig "$f"; echo "ok   tampered target rejected"

if command -v cosign >/dev/null; then
  ( cd repo/publish && exec python3 -m http.server 18911 >/dev/null 2>&1 ) & SRV=$!; sleep 1
  HOME="$W/home" cosign initialize --mirror http://127.0.0.1:18911 --root repo/publish/1.root.json >/dev/null
  test -s "$W/home/.sigstore/root/127.0.0.1-18911/targets/trusted_root.json"
  echo "ok   cosign initialize accepted the repository"
fi
echo "PASS tufctl"
