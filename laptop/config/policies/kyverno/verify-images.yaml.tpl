# Rendered by scripts/12-deploy-policy.sh -> .generated/kyverno-verify-images.yaml
# -----------------------------------------------------------------------------
# Admission control: every Pod image from registry.sigstore.local must carry a
# keyless signature that chains to OUR Fulcio root, has an SCT from OUR CT log,
# a Rekor inclusion proof from OUR Rekor, and an allowed identity.
#
# Kyverno 1.19 ImageValidatingPolicy (policies.kyverno.io/v1, stable).
# Trust comes from the private TUF mirror (12-publish-tuf.sh), which serves the
# same trusted_root.json cosign uses, so Kyverno and developers verify against
# byte-identical trust material and Kyverno never contacts public Sigstore.
# -----------------------------------------------------------------------------
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: require-private-sigstore-signature
  annotations:
    policies.kyverno.io/title: Require keyless signature from the private Sigstore
    policies.kyverno.io/severity: high
spec:
  # Start with [Audit] in an existing cluster, switch to [Deny] once clean.
  validationActions: [${POLICY_ACTION}]
  failurePolicy: Fail
  webhookConfiguration:
    timeoutSeconds: 15
  evaluation:
    background:
      enabled: false
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        operations: ["CREATE", "UPDATE"]
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kyverno, traefik, local-path-storage]
  matchImageReferences:
    - glob: "${REGISTRY_HOST}/*"
  attestors:
    - name: privateSigstore
      cosign:
        keyless:
          identities:
            # Any verified @${DOMAIN} identity from the private realm — humans
            # (alice@...) and the CI service account (ci@...). Tighten to
            # exact subjects per namespace in production (docs/04 §5).
            - issuer: "${OIDC_ISSUER}"
              subjectRegExp: '^[A-Za-z0-9._%+-]+@${DOMAIN_REGEX}$'
        # Trust bootstrap: Kyverno fetches trusted_root.json (Fulcio chain,
        # Rekor key, CT log key) from the PRIVATE TUF mirror, pinned by our
        # TUF root. No public Sigstore endpoint is ever contacted.
        tuf:
          mirror: "${TUF_URL}"
          root:
            data: "${TUF_ROOT_B64}"
        # No "ctlog" block on purpose: with it omitted Kyverno verifies the
        # Rekor inclusion proof and the SCT OFFLINE from the signature bundle
        # using keys from trusted_root.json (no Rekor API call at admission).
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.privateSigstore])).all(e, e > 0)
      message: >-
        Image is not signed by an allowed identity via the private Sigstore
        (Fulcio ${FULCIO_URL}, Rekor ${REKOR_URL}).
