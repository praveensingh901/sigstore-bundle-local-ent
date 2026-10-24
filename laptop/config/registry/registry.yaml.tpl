# Private OCI registry (CNCF Distribution / registry:2) behind Traefik TLS.
# Rendered by scripts/06-deploy-registry.sh.
#   URL:     https://${REGISTRY_HOST}
#   Storage: 10Gi PVC (local-path)
#   Auth:    none on the laptop (bound to 127.0.0.1). For shared/production
#            use Harbor or enable htpasswd/token auth — docs/07-security-hardening.md
apiVersion: v1
kind: Namespace
metadata:
  name: registry
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: registry
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
  labels: { app.kubernetes.io/name: registry }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app.kubernetes.io/name: registry }
  template:
    metadata:
      labels: { app.kubernetes.io/name: registry }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: registry
          image: ${REGISTRY_IMAGE}
          env:
            - { name: REGISTRY_HTTP_ADDR, value: ":5000" }
            # Behind a TLS-terminating proxy: emit relative Location headers.
            - { name: REGISTRY_HTTP_RELATIVEURLS, value: "true" }
            - { name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true" }
            - { name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY, value: /var/lib/registry }
            - { name: OTEL_TRACES_EXPORTER, value: none }
          ports:
            - { name: http, containerPort: 5000 }
          readinessProbe:
            httpGet: { path: /v2/, port: 5000 }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /v2/, port: 5000 }
            periodSeconds: 20
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: data, mountPath: /var/lib/registry }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: registry-data }
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  selector: { app.kubernetes.io/name: registry }
  ports:
    - { name: http, port: 80, targetPort: 5000 }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: registry
  namespace: registry
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${REGISTRY_HOST}]
      secretName: sigstore-tls
  rules:
    - host: ${REGISTRY_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: registry, port: { number: 80 } }
