${DOMAIN}:53 {
    # sigstore-offline: every *.${DOMAIN} name resolves to the Traefik ingress
    # ClusterIP, so pods reach Keycloak/Fulcio/Rekor/registry/TUF through the
    # same TLS endpoints (and certificate) as the laptop does.
    errors
    cache 30
    template IN A ${DOMAIN} {
        answer "{{ .Name }} 60 IN A ${INGRESS_CLUSTER_IP}"
    }
    template IN AAAA ${DOMAIN} {
        rcode NOERROR
    }
}
