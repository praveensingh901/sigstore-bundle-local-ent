#!/usr/bin/env bash
# =============================================================================
# fix-node-dns.sh — point *.sigstore.local at the Traefik ClusterIP inside every
# kind node's /etc/hosts. containerd (which pulls user images from
# registry.sigstore.local) runs in the node, outside the pod network, so it
# cannot use CoreDNS. Docker rewrites /etc/hosts when a node container
# restarts, so run this again after a laptop reboot (verify-stack.sh tells you).
# =============================================================================
source "$(dirname "$0")/lib.sh"
require_cmd docker kind
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "$node" sh -c "
    grep -v '# sigstore-offline' /etc/hosts > /tmp/hosts.new
    echo '${INGRESS_CLUSTER_IP} ${ALL_HOSTS} # sigstore-offline' >> /tmp/hosts.new
    cat /tmp/hosts.new > /etc/hosts"
  ok "${node}: ${ALL_HOSTS} -> ${INGRESS_CLUSTER_IP}"
done
