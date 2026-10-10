# Varco REST Management API Reference

The administrative REST API provides full runtime control over routes, certificates, upstreams, and cluster state.

**Base URL:** `http://localhost:9000` (configurable via `VARCO_ADMIN_PORT`)

---

## 1. System Endpoints

### Ping Health Check
```http
GET /api/v1/ping
```
**Response (200 OK):**
```json
{
  "status": "ok",
  "service": "varco"
}
```

### Metrics & Observability
```http
GET /api/v1/metrics
```
**Response (200 OK):**
```json
{
  "node": "nonode@nohost",
  "uptime_seconds": 1284,
  "beam_memory_bytes": 48234496,
  "beam_processes": 142,
  "beam_schedulers": 24,
  "active_routes_count": 8,
  "active_certificates_count": 3
}
```

### Cluster State
```http
GET /api/v1/cluster
```
**Response (200 OK):**
```json
{
  "current_node": "varco@10.0.1.10",
  "peers": ["varco@10.0.1.11"],
  "node_count": 2,
  "is_clustered": true
}
```

---

## 2. Routes Endpoints

### List Routes
```http
GET /api/v1/routes
```
**Response (200 OK):**
```json
[
  {
    "id": "api-service",
    "hosts": ["api.domain.tld"],
    "path": "/v1",
    "path_type": "prefix",
    "upstreams": ["http://127.0.0.1:4000"],
    "strip_path": false,
    "tls": true,
    "load_balancer": "round_robin",
    "metadata": {}
  }
]
```

### Create / Update Route
```http
POST /api/v1/routes
Content-Type: application/json
```
**Request Body:**
```json
{
  "id": "checkout-route",
  "hosts": ["store.domain.tld"],
  "path": "/checkout",
  "path_type": "prefix",
  "upstreams": [
    "http://10.0.1.50:8080",
    "http://10.0.1.51:8080"
  ],
  "strip_path": false,
  "tls": true,
  "load_balancer": "round_robin",
  "request_headers": [
    {"key": "x-forwarded-by", "value": "varco-gateway"}
  ],
  "response_headers": [
    {"key": "x-gateway", "value": "varco"}
  ]
}
```
**Response (201 Created):** Returns the normalized Route JSON.

### Get Route by ID
```http
GET /api/v1/routes/:id
```
**Response (200 OK or 404 Not Found)**

### Delete Route
```http
DELETE /api/v1/routes/:id
```
**Response (200 OK):**
```json
{
  "status": "deleted",
  "id": "checkout-route"
}
```

---

## 3. Certificates Endpoints

### List Certificates
```http
GET /api/v1/certificates
```
**Response (200 OK):**
```json
[
  {
    "domain": "api.domain.tld",
    "domains": ["api.domain.tld", "localhost"],
    "type": "self_signed",
    "inserted_at": "2026-10-10T10:00:00Z",
    "expires_at": "2027-01-08T10:00:00Z"
  }
]
```

### Upload Custom Certificate
```http
POST /api/v1/certificates
Content-Type: application/json
```
**Request Body:**
```json
{
  "cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
  "key": "-----BEGIN EC PRIVATE KEY-----\n...\n-----END EC PRIVATE KEY-----",
  "domains": ["wildcard.example.com"]
}
```
**Response (201 Created):**
```json
{
  "status": "imported",
  "metadata": {
    "domains": ["wildcard.example.com"],
    "expires_at": "2027-01-08T10:00:00Z"
  }
}
```

### Export Root CA PEM
```http
GET /api/v1/certificates/ca
```
**Response (200 OK):** Returns raw X.509 PEM certificate with Content-Type `application/x-x509-ca-cert`.

---

## 4. Upstream Health Endpoints

### List Upstreams Health
```http
GET /api/v1/upstreams
```
**Response (200 OK):**
```json
[
  {
    "upstream": "http://10.0.1.50:8080",
    "status": "healthy",
    "checked_at": 1791630000
  },
  {
    "upstream": "http://10.0.1.51:8080",
    "status": "unhealthy",
    "checked_at": 1791630000
  }
]
```
