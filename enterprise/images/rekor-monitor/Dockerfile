# rekor-monitor has no published image. Build from a pinned commit, distroless runtime.
#   docker build -t <ecr>/sigstore/rekor-monitor:47017b2379cb enterprise/images/rekor-monitor
# Pin base images by digest when mirroring (Renovate keeps them current).
FROM golang:1.27.1 AS build
ARG REKOR_MONITOR_COMMIT=47017b2379cb
ENV CGO_ENABLED=0 GOFLAGS=-trimpath
RUN go install -ldflags="-s -w" github.com/sigstore/rekor-monitor/cmd/rekor_monitor@${REKOR_MONITOR_COMMIT}

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /go/bin/rekor_monitor /usr/local/bin/rekor_monitor
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/rekor_monitor"]
