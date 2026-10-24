# Keycloak — private OIDC identity provider for keyless signing.
# Rendered by scripts/07-deploy-keycloak.sh. Image: ${KEYCLOAK_IMAGE}
#
# Key settings:
#   KC_HOSTNAME=${OIDC_ISSUER_BASE}  pins the issuer ("iss") to
#       ${OIDC_ISSUER} no matter how Keycloak is reached
#       (laptop via Traefik, Fulcio via CoreDNS -> Traefik). Fulcio rejects
#       tokens whose iss differs from its configured IssuerURL by even one char.
#   KC_HTTP_ENABLED + KC_PROXY_HEADERS=xforwarded: TLS terminates at Traefik.
#   KC_DB=dev-file: embedded H2 on a PVC (laptop). Production: PostgreSQL,
#       2+ replicas (docs/04-enterprise-rollout.md).
#   --import-realm: imports realm "sigstore" from Secret keycloak-realm on first
#       start; ignored when the realm already exists.
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keycloak-data
  namespace: keycloak
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels: { app.kubernetes.io/name: keycloak }
spec:
  replicas: 1
  strategy: { type: Recreate }      # H2 file DB = single writer
  selector:
    matchLabels: { app.kubernetes.io/name: keycloak }
  template:
    metadata:
      labels: { app.kubernetes.io/name: keycloak }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 0
        fsGroup: 0
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: keycloak
          image: ${KEYCLOAK_IMAGE}
          args: ["start", "--import-realm"]
          env:
            - { name: KC_HOSTNAME, value: "${OIDC_ISSUER_BASE}" }
            - { name: KC_HTTP_ENABLED, value: "true" }
            - { name: KC_PROXY_HEADERS, value: xforwarded }
            - { name: KC_HEALTH_ENABLED, value: "true" }
            - { name: KC_METRICS_ENABLED, value: "true" }
            - { name: KC_DB, value: dev-file }
            - { name: KC_CACHE, value: local }
            - { name: JAVA_OPTS_KC_HEAP, value: "-XX:MaxRAMPercentage=70" }
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: admin
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: { secretKeyRef: { name: keycloak-admin, key: password } }
          ports:
            - { name: http, containerPort: 8080 }
            - { name: management, containerPort: 9000 }
          startupProbe:
            httpGet: { path: /health/started, port: 9000 }
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: { path: /health/ready, port: 9000 }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health/live, port: 9000 }
            periodSeconds: 20
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: realm, mountPath: /opt/keycloak/data/import, readOnly: true }
            - { name: data, mountPath: /opt/keycloak/data/h2 }
      volumes:
        - name: realm
          secret: { secretName: keycloak-realm }
        - name: data
          persistentVolumeClaim: { claimName: keycloak-data }
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  selector: { app.kubernetes.io/name: keycloak }
  ports:
    - { name: http, port: 80, targetPort: 8080 }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${KEYCLOAK_HOST}]
      secretName: sigstore-tls
  rules:
    - host: ${KEYCLOAK_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: keycloak, port: { number: 80 } }
