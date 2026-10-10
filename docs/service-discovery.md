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
