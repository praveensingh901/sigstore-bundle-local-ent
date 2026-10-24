# Minimal demo image used by scripts/10-sign-and-verify.sh.
# BASE_IMAGE is loaded from the offline bundle (see config/env.sh DEMO_BASE_IMAGE).
ARG BASE_IMAGE=docker.io/library/busybox:1.37.0
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.title="sigstore-offline demo" \
      org.opencontainers.image.description="Signed keylessly by a private Sigstore stack"
COPY index.html /www/index.html
EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
