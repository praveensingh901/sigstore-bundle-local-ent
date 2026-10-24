# sigstore-platform

Keyless container signing for Example Bank: a private Sigstore (Fulcio, Rekor, CT log, Trillian, Timestamp Authority) on AWS, anchored in the corporate offline root CA, with signatures verified by Kyverno on EKS, AKS, OpenShift and on-prem Kubernetes.

| Folder | What it is | Start here |
|---|---|---|
| [`enterprise/`](enterprise/) | Production design and code: docs 00–10, Terraform, Helm values, GitOps, policies, CI workflows, PKI ceremony and TUF tooling | [`enterprise/docs/00-overview.md`](enterprise/docs/00-overview.md) |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records 0001–0012 | [`docs/adr/README.md`](docs/adr/README.md) |
| [`laptop/`](laptop/) | Fully offline Sigstore kit on a kind cluster, for learning and testing | [`laptop/README.md`](laptop/README.md) |
| [`tutorial/`](tutorial/) | Sigstore Academy: interactive course on every tool (open `tutorial/index.html`) | `python3 tutorial/build.py` |
| [`tools/`](tools/) | `validate.sh` (all static checks) and `crd-schemas.py` | `CHARTS_DIR=… tools/validate.sh` |

## Enterprise layout

```
enterprise/
├── docs/            00 overview · 01 architecture · 02 PKI & ceremony · 03 identity · 04 trust (TUF)
│                    05 consumer clusters · 06 CI (GitHub) · 07 security · 08 operations & DR
│                    09 rollout · 10 deployment runbook
├── exec/            executive summary (Word) and overview deck (PowerPoint) + generators
├── terraform/       modules: kms-signing-keys, private-ca, platform · environments: security, platform-prod, platform-dr
├── helm/            values/{common,prod,dr} · manifests (Keycloak, External Secrets, TUF mirror, monitor, NetworkPolicies)
├── gitops/          Argo CD project, platform apps (prod, dr), consumer ApplicationSets
├── policies/        Kyverno policy pack + tests · identities allow-list · optional OpenShift ClusterImagePolicy
├── consumers/       per-platform overlays (eks, aks, openshift, onprem) and verify-cluster.sh
├── ci/              reusable sign workflow, caller example, promote, third-party import, TUF publish/replicate
├── pki-ceremony/    kms-csr (Go), verify scripts, OpenSSL profiles, ceremony record template, tests
├── pki/             public certificates and keys after the ceremony
├── tuf/             tufctl.py, test, pinned root
├── images/          signing runner image, rekor-monitor image
└── vendor/          Keycloak operator 26.8.1 manifests, Trillian v1.8.0 schema, OpenShift CRD
```

## Status

Validated statically: `tools/validate.sh` runs `helm template`, strict `kubeconform` against the real CRD schemas, Kyverno CLI tests, `terraform validate`, `tflint` and `checkov`; `enterprise/tuf/test.sh` and `enterprise/pki-ceremony/test.sh` exercise the TUF and ceremony tooling end to end. **Nothing has been applied to an AWS account yet.** Follow [`enterprise/docs/10-deployment-runbook.md`](enterprise/docs/10-deployment-runbook.md), starting with a sandbox account set and its smoke test.

Placeholders (`example-bank`, `111111111111`, `222222222222`, `333333333333`, `sigstore.corp.example`, `REPLACE…`) are listed in [`enterprise/docs/00-overview.md`](enterprise/docs/00-overview.md) §4.

## Contributing

Pull requests only; CODEOWNERS approvals apply (`.github/CODEOWNERS`). Run `pre-commit install` once. No secrets in Git — see [`SECURITY.md`](SECURITY.md).
