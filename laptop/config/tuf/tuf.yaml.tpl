# Private TUF mirror. Rendered by scripts/12-publish-tuf.sh.
# The repository (static, signed JSON) arrives as ConfigMap tuf-repo
# (binaryData repository.tar.gz). An init container unpacks it; the
# scaffolding "server" image serves it read-only on :8080.
apiVersion: v1
kind: Namespace
metadata:
  name: tuf-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tuf
  namespace: tuf-system
  labels: { app.kubernetes.io/name: tuf }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: tuf }
  template:
    metadata:
      labels: { app.kubernetes.io/name: tuf }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile: { type: RuntimeDefault }
      initContainers:
        - name: unpack
          # same busybox digest the trillian chart already mirrors
          image: docker.io/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
          command: ["sh", "-c", "tar -xzf /src/repository.tar.gz -C /tuf && ls /tuf/repository"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: src, mountPath: /src, readOnly: true }
            - { name: repo, mountPath: /tuf }
      containers:
        - name: tuf
          image: ${TUF_SERVER_IMAGE}
          args: ["--mode=serve", "--no-k8s", "--target-dir=/tuf"]
          ports:
            - { name: http, containerPort: 8080 }
          readinessProbe:
            httpGet: { path: /root.json, port: 8080 }
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: repo, mountPath: /tuf, readOnly: true }
      volumes:
        - name: src
          configMap: { name: tuf-repo }
        - name: repo
          emptyDir: { sizeLimit: 50Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: tuf
  namespace: tuf-system
spec:
  selector: { app.kubernetes.io/name: tuf }
  ports:
    - { name: http, port: 80, targetPort: 8080 }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tuf
  namespace: tuf-system
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${TUF_HOST}]
      secretName: sigstore-tls
  rules:
    - host: ${TUF_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: tuf, port: { number: 80 } }
