# Varco Architecture & BEAM Internals

This document explains how Varco utilizes the Erlang/BEAM runtime to achieve ultra-high throughput, fault tolerance, and seamless cluster synchronization.

---

## 1. OTP Supervision Tree

Varco is structured as an OTP Application with a fault-tolerant supervision tree:

```
                          Varco.Supervisor
                                 │
   ┌──────────────┬──────────────┼──────────────┬──────────────┐
   │              │              │              │              │
CertificateStore  Table    HealthChecker     Finch        Cluster.Sync
   │              │              │              │              │
   │              │              │              │         Cluster.Discovery
   │              │              │              │              │
   │              │              │              │         Docker.Discovery
   │              │              │              │              │
   │              │              │              │         Kubernetes.Discovery
   │              │              │              │
   └──────────────┴──────────────┴──────────────┘
                                 │
                     ┌───────────┴───────────┐
                     │                       │
               Varco.Server           Varco.API.Server
             (Public Proxy)          (Admin & Dashboard)
```

### Fault Isolation
If an upstream connection experiences an unhandled socket crash or an external client abruptly disconnects, only the transient worker process handling that specific stream terminates. The routing table, certificate cache, and core listener processes remain completely unaffected.

---

## 2. Lock-Free Routing Table

In traditional Go-based reverse proxies, routing lookups often require mutex contention or synchronized map reads under heavy concurrency.

Varco avoids locks entirely by leveraging **Erlang ETS Tables** with `read_concurrency: true`:
* Table: `:varco_routes`
* Lookup Latency: Under **1 microsecond** even across dozens of CPU cores.
* Matching Strategy:
  1. Exact host match (`api.domain.com`)
  2. Wildcard host match (`*.domain.com`)
  3. Catch-all fallback (`hosts: []`)
  4. Specificity sorting based on path length: `/api/v1/users` is evaluated before `/api/v1`, which is evaluated before `/`.

---

## 3. Dynamic SNI Resolution

When a client initiates a TLS handshake with Varco, the Erlang `:ssl` socket triggers the SNI callback function:

```elixir
sni_fun = &Varco.TLS.CertificateStore.sni_fun/1
```

```
[TLS ClientHello] ──(SNI: api.example.com)──> [sni_fun/1]
                                                    │
                                         [Check ETS Cache]
                                            ├── Found ──> [Return DER Cert & Key]
                                            └── Missing ─> [Auto-Sign via Local CA]
                                                                   │
                                                                   ▼
                                                            [Cache in ETS & Return]
```

1. The hostname is queried against `:varco_certificates` in ETS.
2. If a custom or Let's Encrypt certificate is cached, it is returned in raw ASN.1 DER format.
3. If no certificate exists and `auto_self_signed` is enabled (default), Varco's `CertificateStore` issues an elliptic curve certificate on the fly, signed by the in-memory **Varco Root CA**, caches it, and returns it.
4. Subsequent handshakes for the same domain hit ETS with sub-microsecond latency.

---

## 4. Zero-Buffering Response Streaming

Reverse proxies frequently struggle with high memory usage when handling large file downloads, video streams, or Server-Sent Events (SSE).

Varco uses **Finch** and **Mint** to establish raw streaming connections:
* Response chunks received from the backend upstream are immediately written to the client socket using `Plug.Conn.chunk/2`.
* Chunks are never collected or buffered into memory heaps.
* Varco's RAM usage remains flat whether proxying a 10 KB JSON payload or a 10 GB file download.

---

## 5. Hop-by-Hop Header Sanitization

To ensure RFC 7230 compliance and prevent HTTP Request Smuggling, Varco automatically strips all hop-by-hop headers before forwarding requests to backend upstreams:
* `connection`
* `keep-alive`
* `proxy-authenticate`
* `proxy-authorization`
* `te`
* `trailers`
* `transfer-encoding`
* `upgrade`

Standard proxy headers are injected and chained:
* `X-Forwarded-For`: Appends client IP to existing chain.
* `X-Forwarded-Proto`: Specifies `:http` or `:https`.
* `X-Forwarded-Host`: Original client request host.
* `X-Real-IP`: Client remote socket address.
