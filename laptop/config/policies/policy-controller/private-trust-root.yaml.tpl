# Sigstore policy-controller alternative to Kyverno (REFERENCE — not part of
# the tested install path; validate in your environment).
# Render: TUF_URL, TUF_ROOT_B64 (base64 of out/tuf/root.json), OIDC_ISSUER.
# The policy-controller webhook pods also need pki/tls/ca.crt in their trust
# store to reach tuf.sigstore.local and registry.sigstore.local.
apiVersion: policy.sigstore.dev/v1alpha1
kind: TrustRoot
metadata:
  name: private-sigstore
spec:
  remote:
    mirror: ${TUF_URL}
    root: ${TUF_ROOT_B64}
---
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-private-sigstore-signature
spec:
  images:
    - glob: "registry.sigstore.local/**"
  authorities:
    - name: private-keyless
      keyless:
        trustRootRef: private-sigstore
        identities:
          - issuer: ${OIDC_ISSUER}
            subjectRegExp: '^[A-Za-z0-9._%+-]+@sigstore\.local$'
      ctlog:
        url: https://rekor.sigstore.local
        trustRootRef: private-sigstore
