# TLS, Local CA & Let's Encrypt Guide

Varco is designed with a **secure-by-default** philosophy. All routes default to TLS (`tls: true`) and plain HTTP requests on port 80/8080 are automatically upgraded with a `308 Permanent Redirect`.

---

## 1. Zero-Config Self-Signed Certificates

When starting Varco, the `Varco.TLS.CertificateStore` generates an internal cryptographic **Root Certificate Authority (CA)**:
* **Algorithm:** ECDSA (`secp256r1`)
* **Validity:** 10 Years
* **Subject:** `CN=Varco Development Authority, O=Varco Proxy, C=DE`

### How On-the-Fly Issuance Works
When an HTTPS request arrives for any host (e.g. `dev.myapp.local`), Varco checks its memory cache:
1. If no certificate exists, it generates a leaf key pair.
2. It signs the certificate with the Root CA, embedding the requested domain in the **Subject Alternative Name (SAN)** extension.
3. The certificate is cached in ETS and immediately used to complete the TLS handshake.

### Trusting Varco Locally
To eliminate browser warnings (`NET::ERR_CERT_AUTHORITY_INVALID`) during local development:

1. Download your node's Root CA certificate:
   ```bash
   curl -O http://localhost:9000/api/v1/certificates/ca
   ```

2. Add it to your operating system trust store:
   * **macOS:**
     ```bash
     sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain varco-root-ca.crt
     ```
   * **Ubuntu / Debian:**
     ```bash
     sudo cp varco-root-ca.crt /usr/local/share/ca-certificates/varco.crt
     sudo update-ca-certificates
     ```
   * **Fedora / RHEL:**
     ```bash
     sudo cp varco-root-ca.crt /etc/pki/ca-trust/source/anchors/varco.crt
     sudo update-ca-trust
     ```

Once installed, all domains routed through Varco will display a green padlock in Chrome, Firefox, Safari, and `curl`.

---

## 2. Let's Encrypt / ACME HTTP-01 Challenges

Varco natively integrates with the **ACME v2 protocol** (RFC 8555) for production deployments.

### HTTP-01 Challenge Pipeline
1. When an ACME challenge is initiated, the authorization token is registered in Varco:
   ```elixir
   Varco.TLS.ACME.register_challenge(token, key_authorization, "api.example.com")
   ```
2. The Let's Encrypt validation server sends a `GET` request to:
   ```text
   http://api.example.com/.well-known/acme-challenge/<token>
   ```
3. Varco's `Proxy.Handler` intercepts this path **before** any route lookups or HTTPS redirects occur.
4. It serves the `key_authorization` with status `200 OK` and Content-Type `text/plain`.

### The Cluster Advantage
In a multi-node cluster, Varco automatically broadcasts ACME challenge tokens to all connected BEAM nodes via `Varco.Cluster.Sync`. Even if the ACME server contacts a different proxy node in your pool, that node responds with the valid authorization token immediately.

---

## 3. Uploading Custom Certificates

If you already own a commercial SSL certificate or wildcard certificate (e.g. `*.mycompany.com`), you can upload it via the REST API:

```bash
curl -X POST http://localhost:9000/api/v1/certificates \
  -H "Content-Type: application/json" \
  -d '{
    "cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
    "key": "-----BEGIN EC PRIVATE KEY-----\n...\n-----END EC PRIVATE KEY-----"
  }'
```

Varco extracts all Subject Alternative Names (SANs) and the Common Name (CN) from the certificate and hot-loads it into ETS. Future TLS handshakes matching those hostnames or wildcards will immediately use your custom certificate without restarting the server.

---

## 4. cert-manager & Kubernetes TLS Secrets

In Kubernetes clusters where [cert-manager](https://cert-manager.io/) provisions TLS certificates (e.g. from Let's Encrypt), certificates are stored as Kubernetes Secrets of type `kubernetes.io/tls`.

Varco seamlessly synchronizes with these secrets:
* **Fullchain PEMs:** Both leaf certificates and intermediate CA certificate chains are extracted and served via dynamic SNI with `cacerts`.
* **Private Key Formats:** Supports PKCS#1 (RSA), PKCS#8 (RSA/ECDSA), and SEC1 (EC) private keys.
* **Automatic Renewal:** When cert-manager rotates or renews a certificate secret, Varco's Ingress synchronization picks up the new certificate and immediately updates the active TLS certificate store with zero downtime.
