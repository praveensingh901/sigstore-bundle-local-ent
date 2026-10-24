# Runner image for the ARC scale sets "sigstore-signing" (signing) and "sigstore-verify"
# (pull-request commit verification, no network path to Fulcio/Rekor) (06-ci-github.md §1).
# Rebuilt monthly by the platform pipeline, signed by sign.yml, mirrored to ECR.
# Tool binaries are downloaded on the build host, checksum-verified, and COPY'd in,
# so the image build itself needs no internet.
#   ./fetch-tools.sh && docker build -t <ecr>/ci/sigstore-runner:<date> .
FROM ghcr.io/actions/actions-runner:2.338.1
USER root
COPY tools/cosign tools/crane tools/oras tools/jq tools/gitsign tools/export-trust.sh /usr/local/bin/
COPY ca.crt /etc/sigstore/ca.crt
COPY tuf-root.json /etc/sigstore/tuf-root.json
RUN chmod 0755 /usr/local/bin/cosign /usr/local/bin/crane /usr/local/bin/oras /usr/local/bin/jq \
    /usr/local/bin/gitsign /usr/local/bin/export-trust.sh \
 && chmod 0644 /etc/sigstore/ca.crt /etc/sigstore/tuf-root.json \
 && cp /etc/sigstore/ca.crt /usr/local/share/ca-certificates/example-bank-root.crt && update-ca-certificates
USER runner
