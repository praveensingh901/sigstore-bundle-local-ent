# kind cluster definition. Rendered by scripts/04-create-cluster.sh into
# .generated/kind-config.yaml (absolute host paths are filled in).
#
#  * One control-plane node (laptop-sized; add workers if you have >16 GB RAM).
#  * Host ports 80/443 on 127.0.0.1 -> node -> Traefik (hostPort), so
#    https://*.sigstore.local on the laptop reaches the cluster ingress.
#  * /etc/containerd/certs.d is mounted from .generated/containerd/certs.d:
#      - every upstream registry (docker.io, ghcr.io, quay.io, ...) is
#        redirected to the offline mirror container "sigstore-mirror"
#      - registry.sigstore.local is trusted via our TLS root CA
#    kind node images >= v0.27 already enable config_path=/etc/containerd/certs.d
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
    image: ${KIND_NODE_IMAGE_LOCAL}   # loaded from bundle; digest verified at bundle time
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        listenAddress: "127.0.0.1"
        protocol: TCP
    extraMounts:
      - hostPath: ${GEN_DIR}/containerd/certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
