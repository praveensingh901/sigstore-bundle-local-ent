# 09 — FAQ

**Is this really offline?**
Yes, after phase A. Phase A (`01-build-offline-bundle.sh`) runs once on a
connected machine. On the laptop, images come from the local mirror, every
hostname is `*.sigstore.local`, and cosign/Kyverno use only the private trust
root. The integration test runs all client operations inside a Docker network
created with `--internal` and first asserts that `https://rekor.sigstore.dev`
is unreachable.

**Why kind and not k3d or minikube?**
kind runs anywhere Docker runs (Linux, Docker Desktop on Windows/macOS),
supports containerd `hosts.toml` registry mirrors out of the box (node images
≥ v0.27 set `config_path=/etc/containerd/certs.d`), and is what the Sigstore
projects themselves test with. k3d works with the same Helm values; replace
`04-create-cluster.sh` with a k3d `registries.yaml` mirror config.

**Why Traefik instead of ingress-nginx?**
The Kubernetes project retired ingress-nginx (best-effort maintenance ended
March 2026). Any controller that serves the Ingress objects with TLS works —
change `className` in the values files.

**Why both a `trusted_root.json` file and a TUF mirror?**
The file is the simplest thing that works (`--trusted-root`). The TUF mirror is
how you distribute and *rotate* that file securely at scale, and Kyverno 1.19
requires a TUF source for keyless verification. Both carry byte-identical
content.

**Does verification need Rekor or Fulcio to be online?**
No. cosign v3 bundles contain the certificate, SCT, signed entry timestamp and
inclusion proof; verification needs only `trusted_root.json`. Signing needs
Keycloak, Fulcio, CT log and Rekor.

**What happens when the 10-minute certificate expires?**
Nothing bad. Verifiers check that the Rekor integrated time falls inside the
certificate's validity — proof the signature was made while the certificate
was valid.

**Can I use my corporate Active Directory?**
Yes — federate AD/LDAP into Keycloak (User Federation) or broker Entra ID/ADFS/
Okta through Keycloak; Fulcio keeps trusting one issuer. See docs/04 §3.

**Can I keep using long-lived keys (`cosign generate-key-pair`)?**
Yes, and they can still be logged in your private Rekor. Keyless is preferred
because there is no signing key to protect or rotate, and identities are
auditable in the CT log and Rekor.

**Do I need the CT log?**
Fulcio embeds an SCT so certificate issuance is publicly (here: privately)
auditable, and cosign verifies the SCT by default. You can run Fulcio with
`disable_ct_log: true` and verify with `--insecure-ignore-sct`, but you lose
detection of mis-issued certificates. Keep it.

**Why is the CT key encrypted differently from the other keys?**
The CT front-end only decrypts legacy `Proc-Type: 4,ENCRYPTED` PEM
(`x509.DecryptPEMBlock`); Fulcio and Rekor accept modern encrypted PKCS#8.

**Why does Fulcio need `CACert`?**
Fulcio's image is distroless and has no idea about your private TLS root. The
per-issuer `CACert` field adds it only for OIDC discovery/JWKS calls to that
issuer.

**Where is a timestamp authority (TSA)?**
Not required: Rekor's signed integrated time provides the trusted time. For
RFC 3161 timestamps (e.g. Rekor v2 / tiles logs or regulatory needs) deploy the
`sigstore/tsa` chart and add `--tsa`/`--tsa-config` to `cosign signing-config
create` and `--tsa` to `cosign trusted-root create`.

**Rekor v1 or Rekor v2 (tiles)?**
This kit uses Rekor v1 on Trillian — mature, with the `sigstore/rekor` chart
and full search API. Rekor v2 (`rekor-tiles` chart) is the future direction;
the trust model and client configuration (signing config `api-version=2`)
are the same, so migration is mostly server-side.

**Can I run this on Windows without WSL?**
The scripts need bash + Linux tooling. Docker Desktop on Windows already runs
a Linux VM; WSL2 is the supported shell. Native `cosign.exe` is supported for
signing/verifying (`windows/cosign-windows.ps1`).

**How big is the bundle?**
About **5.1 GB** for the pinned versions (measured): 4.2 GB image mirror (full
multi-arch indexes, so digests match), ~400 MB host images (kind node, registry,
TUF server, busybox), ~475 MB tools incl. the Windows binaries.

**What resources does it need?**
About 3–4 GB RAM in steady state (Keycloak ~700 MB, MySQL ~500 MB, Kyverno
~400 MB, the rest small). Give Docker 8 GB.

**How do I add another signer?**
Create the user in Keycloak with *Email verified* on (docs/05 §7). Adjust the
Kyverno policy if identities are pinned.

**How do I start over?**
`scripts/99-teardown.sh` (keeps keys) or `--purge` (destroys the trust root),
then `install-all.sh`.
