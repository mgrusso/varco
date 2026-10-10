# BEAM Clustering & Multi-Node ACME

One of Varco's most significant competitive advantages over traditional Go proxies is **native BEAM clustering**. 

While Go tools require Raft consensus algorithms, Consul agents, or paid enterprise licenses to share state across multiple instances, Varco forms a decentralized, fault-tolerant cluster natively using Erlang Distribution.

---

## 1. How Cluster State Sync Works

Varco uses Erlang's built-in `:pg` (Process Groups) mechanism for ultra-fast, distributed message distribution:

```
┌─────────────────┐             ┌─────────────────┐
│  Varco Node A   │  Erlang RPC │  Varco Node B   │
│                 │◄───────────►│                 │
│  :varco_routes  │             │  :varco_routes  │
└────────┬────────┘             └────────┬────────┘
         │                               │
         │ Broadcast Event               │
         ▼                               ▼
 [Route Added on Node A] ───► [Instantly Updated in Node B's ETS]
```

### Zero-Touch State Hydration
When a new Varco node boots up and joins the cluster:
1. It detects existing peers via `:nodeup` events.
2. It requests an authoritative state snapshot from a peer: `{:request_snapshot, pid}`.
3. The peer responds with all active routes.
4. The new node populates its local ETS table in milliseconds and is immediately ready to handle traffic.

---

## 2. Distributed Let's Encrypt Coordination

In high-availability setups with a DNS Round-Robin or Cloud Load Balancer in front of multiple proxy nodes, Let's Encrypt validation becomes tricky:

1. **The Issue in Other Proxies:**
   Node 1 initiates an ACME order with Let's Encrypt.
   Let's Encrypt sends an HTTP-01 challenge verification request to `http://example.com/.well-known/acme-challenge/<token>`.
   The external load balancer directs the verification request to **Node 2**.
   Node 2 does not have the token, returning `404 Not Found`. The certificate order fails!
   *(Traefik locked this feature behind Traefik Enterprise).*

2. **The Varco Solution:**
   When Node 1 generates an ACME challenge token, `Varco.Cluster.Sync` broadcasts it across the cluster:
   ```elixir
   Varco.Cluster.Sync.broadcast_acme_challenge(token, key_auth, domain)
   ```
   All Varco nodes cache the token in their local `:varco_acme_challenges` ETS table. Whichever node receives the request answers it immediately with `200 OK`.

---

## 3. Configuring Cluster Discovery (`libcluster`)

Varco supports multiple discovery strategies via environment variables:

### 1. Kubernetes DNS Strategy (Recommended for K8s)
```bash
export VARCO_CLUSTER_STRATEGY=kubernetes
export VARCO_K8S_SERVICE_NAME=varco-headless
export VARCO_K8S_APP_NAME=varco
```
Pods in the Deployment or DaemonSet discover each other automatically via the Headless Service SRV/A records.

### 2. Multicast Gossip Strategy (Local LAN & Bare-Metal)
```bash
export VARCO_CLUSTER_STRATEGY=gossip
```
Nodes on the same subnet broadcast UDP heartbeats and connect without manual IP configuration.

### 3. Static EPMD Strategy
```bash
export VARCO_CLUSTER_STRATEGY=epmd
export VARCO_CLUSTER_HOSTS="node1.lan,node2.lan"
```
Connects explicitly to designated hostnames.

---

## 4. Checking Cluster Status

You can inspect cluster health at any time:
```bash
curl http://localhost:9000/api/v1/cluster
```

Response:
```json
{
  "current_node": "varco@10.0.1.20",
  "peers": [
    "varco@10.0.1.21",
    "varco@10.0.1.22"
  ],
  "node_count": 3,
  "is_clustered": true
}
```
