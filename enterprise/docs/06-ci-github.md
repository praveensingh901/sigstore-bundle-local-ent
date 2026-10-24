# 06 CI with GitHub Enterprise Cloud

## 1. Runners

Signing jobs run on **self-hosted runners** in the CI AWS account, managed by GitHub Actions Runner Controller (ARC 0.15.1, charts `gha-runner-scale-set-controller` and `gha-runner-scale-set`) on an EKS cluster ([ADR-0009](../../docs/adr/0009-self-hosted-runners.md)).

| Item | Setting |
|---|---|
| Registration | GitHub App installed on the enterprise/org; credentials in Secrets Manager, synced by External Secrets |
| Runner group | `sigstore-signing`, restricted to the `platform-workflows` repository's reusable workflows (runner-group "selected workflows" access) |
| Image | Hardened runner image (`enterprise/images/runner`) with cosign v3.1.3, crane, oras, jq, gitsign v0.18.0 and `export-trust.sh`; `/etc/sigstore/ca.crt` (corporate root) and `/etc/sigstore/tuf-root.json` baked in; rebuilt and signed monthly |
| Network | Private subnets; reach `*.sigstore.corp.example`, ECR, GitHub (`github.com`, `*.actions.githubusercontent.com`, `ghcr.io` as needed) through egress inspection |
| Ephemeral | One job per pod (ARC default); no state survives a job |

## 2. One reusable signing workflow

Repositories do not call cosign themselves. They call a reusable workflow owned by the platform team. Because Fulcio puts `job_workflow_ref` in the certificate SAN, every production signature names the **same reviewed workflow**, while the calling repository is recorded in the `githubWorkflowRepository` / `source-repository-*` extensions.

`example-bank/platform-workflows/.github/workflows/sign.yml` (source in `enterprise/ci/sign-reusable.yml`):

```yaml
on:
  workflow_call:
    inputs:
      image: { required: true, type: string }       # registry/repo (no tag)
      digest: { required: true, type: string }      # sha256:...
      sbom-path: { required: false, type: string }
jobs:
  sign:
    runs-on: [self-hosted, sigstore-signing]
    permissions: { id-token: write, contents: read }
    steps:
      - name: Trust private Sigstore
        run: |
          cat /etc/ssl/certs/ca-certificates.crt /etc/sigstore/ca.crt > "$RUNNER_TEMP/ca.pem"
          echo "SSL_CERT_FILE=$RUNNER_TEMP/ca.pem" >> "$GITHUB_ENV"
          cosign initialize --mirror https://tuf.sigstore.corp.example --root /etc/sigstore/tuf-root.json
      - name: Sign
        run: cosign sign --yes "${{ inputs.image }}@${{ inputs.digest }}"
      - name: Attest SBOM
        if: inputs.sbom-path != ''
        run: cosign attest --yes --type spdxjson --predicate "${{ inputs.sbom-path }}" "${{ inputs.image }}@${{ inputs.digest }}"
      - name: Verify like admission control will
        run: |
          cosign verify \
            --certificate-identity "https://github.com/example-bank/platform-workflows/.github/workflows/sign.yml@refs/heads/main" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com/example-bank" \
            --certificate-github-workflow-repository "${{ github.repository }}" \
            "${{ inputs.image }}@${{ inputs.digest }}" > /dev/null
```

The SAN names the reusable workflow, not the caller's branch, so `sign.yml` refuses to run unless the caller's `github.ref` is `refs/heads/main` or a `refs/tags/v*` release tag **and** the triggering event is `push`, `workflow_dispatch` or `release`. Events such as `pull_request_target` and `workflow_run` report the base branch as `github.ref` while the caller may have built untrusted pull-request code, so they are refused. Tags must be protected by an **organisation ruleset** (only release managers may create `v*` tags) — a prerequisite in [10-deployment-runbook.md](10-deployment-runbook.md) §0. Note that `sign.yml` signs whatever digest the caller passes, within what the caller's `aws-role-arn` can push; the team policies that bind a namespace to its repository (05 §3) are what contain a misused caller. The caller's ref is still recorded in the certificate (`githubWorkflowRef`), and team policies can pin it (`05-consumer-clusters.md` §3).

After `cosign initialize`, cosign reads the signing config (Fulcio, Rekor, TSA and OIDC URLs) and the trusted root from your TUF repository, so no URLs appear in the workflow. Inside GitHub Actions cosign obtains the OIDC token itself (audience `sigstore`).

Caller (any application repository):

```yaml
name: release
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: [self-hosted, build]
    permissions:
      id-token: write          # for the ECR login role (aws-actions/configure-aws-credentials)
      contents: read
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      # ... configure AWS credentials, build, scan ...
      - id: push
        run: |
          crane push image.tar "$IMAGE:${GITHUB_SHA::12}"
          echo "digest=$(crane digest "$IMAGE:${GITHUB_SHA::12}")" >> "$GITHUB_OUTPUT"
        env:
          IMAGE: 333333333333.dkr.ecr.me-central-1.amazonaws.com/payments/api
  sign:
    needs: build
    uses: example-bank/platform-workflows/.github/workflows/sign.yml@main
    permissions:
      id-token: write
      contents: read
    with:
      image: 333333333333.dkr.ecr.me-central-1.amazonaws.com/payments/api
      digest: ${{ needs.build.outputs.digest }}
```

The full, lint-checked versions are `enterprise/ci/sign-reusable.yml` and `enterprise/ci/example-caller.yml`.

The SBOM attestation step is optional in the reusable workflow; the SBOM file must be passed from the build job as an artifact.

## 3. Branch and repository protections that the policy relies on

The signature proves *which workflow on which ref* produced the image. That is only meaningful if:

- `platform-workflows` requires reviews from the platform team (CODEOWNERS) and gitsign-signed commits, enforced by the organisation ruleset rule "Require workflows to pass before merging" with `verify-commits.yml` at a pinned ref ([11-gitsign.md](11-gitsign.md) §3; not a status check by name, and not GitHub's "Require signed commits" rule, which rejects private-CA signatures); rulesets block force-pushes and deletion of `main`.
- Application repositories protect `main` (required reviews, required status checks).
- Enterprise policy restricts which actions may run (allow-list), and the `sigstore-signing` runner group is limited to `platform-workflows`.

## 4. Promotion between registries

`enterprise/ci/promote.yml` copies an image **with its signature bundles** from ECR to ACR or Harbor with `oras cp -r` (which copies OCI referrers, falling back to the referrers tag schema where a registry has no referrers API), then runs `cosign verify` against the destination before reporting success. `cosign copy` is **not** used: in cosign v3.1.3 it copies only the legacy `.sig`/`.att`/`.sbom` tags (`cmd/cosign/cli/copy/copy.go`), not the v3 bundles stored as referrers.

## 5. Staff and other CI systems

People sign through the staff realm (browser or device flow) only for break-glass. Any non-GitHub CI that must sign (for example a legacy Jenkins controller) gets a confidential Keycloak client in a separate `ci` realm with an e-mail-style service identity (`jenkins-prod@ci.example-bank.com`), and policies list it explicitly where allowed.
