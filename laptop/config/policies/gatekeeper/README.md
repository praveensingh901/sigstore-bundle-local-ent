# OPA Gatekeeper option

Gatekeeper evaluates Rego against the admission request. **It cannot verify a
cosign signature by itself**: signature checks need an
[external data provider](https://open-policy-agent.github.io/gatekeeper/website/docs/externaldata)
(for example Ratify, or a small in-house service wrapping `cosign verify`).

What this kit ships and recommends:

| Concern | Enforced by | File |
|---|---|---|
| Images must come from `registry.sigstore.local` and be pinned by digest | Gatekeeper (Rego, no external calls) | `require-digest-from-private-registry.yaml` |
| Image digest must carry a keyless signature from the private Fulcio/Rekor with an allowed identity | Kyverno `ImageValidatingPolicy` (tested end-to-end offline) | `../kyverno/verify-images.yaml.tpl` |

Running both is supported: they register separate webhooks and every Pod must
pass both.

If Gatekeeper must own signature verification too, deploy an external data
provider that:

1. bootstraps trust with `cosign initialize --mirror https://tuf.sigstore.local --root root.json`
   (or reads `trusted_root.json` directly);
2. exposes `POST /validate` that runs the equivalent of
   `cosign verify --certificate-identity-regexp '@sigstore\.local$' --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore <image@digest>`
   and returns allow/deny in the Gatekeeper external-data response format;
3. serves TLS with a cert from `pki/tls` and is registered via a `Provider`
   resource whose `caBundle` is `pki/tls/ca.crt`.

Validate any third-party provider against **cosign v3 bundles (OCI referrers)
and a private Fulcio root** before relying on it — that combination is what
this kit produces.
