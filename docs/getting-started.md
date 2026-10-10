# Getting Started with Varco

This guide walks you through setting up and running **Varco** as your reverse proxy in under five minutes.

---

## 1. Prerequisites
* **Elixir 1.15+** and **Erlang/OTP 26+** (tested and optimized through Erlang/OTP 29)
* Git

---

## 2. Installation and First Run

### Option A: Run via Prebuilt Container (Recommended)
```bash
docker run -d --name varco \
  -p 80:8080 -p 443:8443 -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/mgrusso/varco:latest
```

### Option B: Build from Source
Clone the repository and fetch the dependencies:
```bash
git clone https://github.com/mgrusso/varco.git
cd varco
mix deps.get
```

Start the Varco node:
```bash
mix run --no-halt
```

Upon startup, you will observe the supervision tree initializing:
```text
12:00:00.000 [info] Varco TLS Certificate Store initialized (auto_self_signed: true)
12:00:00.010 [info] Varco listeners configured: HTTP port 8080, HTTPS port 8443
12:00:00.012 [info] Varco Admin API & Dashboard configured on port 9000
```

---

## 3. Verifying the Endpoints

Varco runs three listeners by default:
1. **Public HTTP:** `http://localhost:8080` (redirects to HTTPS if route requires TLS)
2. **Public HTTPS:** `https://localhost:8443` (dynamic SNI + auto self-signed certificates)
3. **Admin & Dashboard:** `http://localhost:9000` (REST API & Web UI)

Open your browser and navigate to:
```text
http://localhost:9000/dashboard
```
You will see the embedded, real-time dashboard displaying active routes, certificates, and BEAM health metrics.

---

## 4. Registering Your First Route

Varco supports dynamic runtime configuration without process restarts. Open a terminal and register a route using `curl`:

```bash
curl -X POST http://localhost:9000/api/v1/routes \
  -H "Content-Type: application/json" \
  -d '{
    "id": "my-local-app",
    "host": "localhost",
    "path": "/",
    "upstreams": ["http://httpbin.org"],
    "tls": false
  }'
```

Now, query your reverse proxy:
```bash
curl -i http://localhost:8080/get
```
You will receive the response forwarded directly from `httpbin.org` with standard proxy headers attached (`X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`).

---

## 5. Testing Zero-Config HTTPS

Create a route with TLS enabled (the default):
```bash
curl -X POST http://localhost:9000/api/v1/routes \
  -H "Content-Type: application/json" \
  -d '{
    "id": "secure-app",
    "host": "test.local",
    "path": "/",
    "upstreams": ["http://httpbin.org"],
    "tls": true
  }'
```

Now send an HTTPS request with SNI:
```bash
curl -k --resolve test.local:8443:127.0.0.1 https://test.local:8443/get
```

Notice what happened behind the scenes:
1. Varco's Erlang `:ssl` handshake inspected the SNI hostname `test.local`.
2. It dynamically generated an elliptic curve (`secp256r1`) certificate signed by Varco's local Root CA.
3. The certificate was cached in ETS in microseconds and served to the client.

To make your browser trust all local certificates issued by Varco, download the root CA:
```bash
curl -O http://localhost:9000/api/v1/certificates/ca
```
Install `varco-root-ca.crt` into your operating system's trust store once, and you will have trusted HTTPS across all development domains!

---

## 6. Running with Static Configuration File

Instead of using the REST API, you can define your infrastructure declaratively in `varco.yaml`:

```yaml
routes:
  - id: web-frontend
    host: app.internal
    path: /
    upstreams:
      - http://127.0.0.1:3000
    tls: true

  - id: backend-api
    host: app.internal
    path: /api
    strip_path: true
    upstreams:
      - http://127.0.0.1:4000
    tls: true
```

Launch Varco pointing to the file:
```bash
VARCO_CONFIG=varco.yaml mix run --no-halt
```
Varco will load and activate all routes immediately.
