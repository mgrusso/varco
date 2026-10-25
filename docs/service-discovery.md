# Service Discovery in Varco

Varco embraces the philosophy of **Convention over Configuration**. Deploying a service should not require deciphering complex router and middleware hierarchies.

---

## 1. Docker & Podman Container Discovery

Varco communicates directly with the Docker or Podman daemon socket (`/var/run/docker.sock`).

### The Minimal Zero-Config Example
To route traffic to a container, add **a single label**:

```yaml
services:
  web:
    image: nginx:alpine
    expose:
      - "80"
    labels:
      - "varco.host=site.example.com"
```

Varco inspects the container metadata upon startup:
1. Detects exposed port `80`.
2. Resolves container bridge IP (e.g. `172.17.0.2`).
3. Generates a route to `http://172.17.0.2:80`.
4. Automatically provisions a TLS certificate for `site.example.com`.

### Full Docker Labels Reference
| Label | Description | Default |
| :--- | :--- | :--- |
| `varco.enable` | Explicitly enable or disable proxying | `true` (if `varco.host` is set) |
| `varco.host` | Hostname(s) to match (comma-separated) | `<container_name>.local` |
| `varco.port` | Explicit backend port to target | First exposed container port |
| `varco.path` | Path prefix to match | `/` |
| `varco.strip_path` | Strip the prefix before sending upstream | `false` |
| `varco.tls` | Enable or disable TLS for this route | `true` |
| `varco.load_balancer` | Load balancing algorithm (`round_robin` or `random`) | `round_robin` |
| `varco.scheme` | Backend upstream scheme (`http` or `https`) | `http` |

---

## 2. Kubernetes Ingress Controller

Varco functions as a native Ingress Controller for Kubernetes clusters.

### Example Ingress Resource
Deploy standard `networking.k8s.io/v1` Ingress manifests using `ingressClassName: varco`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: customer-api
  namespace: production
  annotations:
    varco.io/strip-path: "false"
    varco.io/load-balancer: "round_robin"
spec:
  ingressClassName: varco
  tls:
    - hosts:
        - api.customer.io
  rules:
    - host: api.customer.io
      http:
        paths:
          - path: /v1
            pathType: Prefix
            backend:
              service:
                name: customer-service
                port:
                  number: 8080
```

### Supported Ingress Annotations
* `varco.io/strip-path`: `"true"` or `"false"` (default: `"false"`)
* `varco.io/load-balancer`: `"round_robin"` or `"random"` (default: `"round_robin"`)
* `varco.io/upstream-scheme`: `"http"` or `"https"` (default: `"http"`)
* `varco.io/proxy-timeout` or `varco.io/timeout`: Timeout in milliseconds or `"infinity"` (default: `300000`)

### Automatic API Sync & cert-manager Integration
When running inside a Kubernetes cluster (or configured via `KUBERNETES_API_URL` and `KUBERNETES_TOKEN`), Varco's `Varco.Discovery.Kubernetes` automatically:
1. Polls `/apis/networking.k8s.io/v1/ingresses` for Ingress resources matching `ingressClassName: varco`.
2. Synchronizes discovered routes dynamically into Varco's lock-free routing table, removing stale routes on Ingress deletion.
3. Reads any referenced TLS secrets (`spec.tls[*].secretName`) from `/api/v1/namespaces/{namespace}/secrets/{secret_name}`. Decodes `tls.crt` and `tls.key` (supporting Let's Encrypt certificates managed by cert-manager) and installs them in `Varco.TLS.CertificateStore`.
4. Synchronizes and updates `.status.loadBalancer.ingress` on managed Ingress resources when `VARCO_K8S_PUBLISH_STATUS_ADDRESS` or `VARCO_K8S_STATUS_IP` is configured (supporting both IP addresses and hostnames), ensuring GitOps tools such as ArgoCD immediately reflect healthy Ingress status.
Varco resolves upstream service endpoints using cluster-internal DNS:
```text
http://customer-service.production.svc.cluster.local:8080
```
---

## 3. Static File Configuration

For static environments, configure Varco via `varco.yaml` or `varco.json`:

```yaml
routes:
  - id: billing-service
    hosts:
      - billing.internal
      - pay.internal
    path: /
    path_type: prefix
    upstreams:
      - http://10.0.1.5:8000
      - http://10.0.1.6:8000
    strip_path: false
    tls: true
    load_balancer: round_robin
    request_headers:
      - key: x-client-source
        value: "varco-edge"
    response_headers:
      - key: x-proxy-by
        value: "varco"
```
