# aeo: Migration Guide from Docker Compose and Kubernetes

This guide helps you move existing workloads from Docker Compose or Kubernetes to aeo. Both journeys are different; pick the section that matches your starting point.

## Migration from Docker Compose

Docker Compose is the closest cousin to aeo — both orchestrate containers on a single host with health checks and dependencies. Migration is straightforward.

### 1. Translate Services to Nodes

In docker-compose.yml:
```yaml
services:
  db:
    image: redis:alpine
    healthcheck:
      test: redis-cli ping
      interval: 10s
```

In aeo composition (Aether code):
```aether
import compose (system, container, health, depends)

aeo_orchestration() {
    system("myapp") {
        within(30s)
        db = container("db") {
            image("docker.io/library/redis:alpine")
            health("redis-cli ping")
        }
    }
}
```

**Key differences:**
- `services` → `container("name")` (or `jail`, `bhyve_vm` for other kinds)
- `healthcheck.test` → `health("command")`
- `depends_on: [db]` → `depends(db)` (explicit reference in Aether)
- No YAML — it's real code (conditionals, env vars, loops work)

### 2. Translate Volumes to Mounts

Docker Compose:
```yaml
services:
  app:
    volumes:
      - /var/data:/data
      - db_data:/var/lib/postgresql
```

aeo (currently): **Volumes are future work** (`docs/research/` has investigation).

**Workaround for now:**
- Use `aeo exec` to run setup commands inside the node
- Or pre-populate data in the container image
- Or use bind-mounts (passed via driver at runtime — not yet in DSL)

### 3. Translate Networks to Network Policy

Docker Compose:
```yaml
services:
  db:
    networks:
      - internal
  web:
    networks:
      - internal
      - public
networks:
  internal:
    driver: bridge
  public:
    driver: bridge
```

aeo (simplified):
```aether
db = container("db") {
    health("...")
    constrain("db") { deny_egress() }  // Internal only, no egress
}
web = container("web") {
    depends(db)
    // Web can reach db (same compose system)
    constrain("web") { /* leave open or add peer-only */ }
}
```

**Key difference:** aeo doesn't have explicit network objects. Instead:
- `deny_egress()` — no outbound network (like `internal` network in Compose)
- Default — can reach peers and the host
- Future: `peer_egress()` for "only reach this peer"

### 4. Translate Environment Variables

Docker Compose:
```yaml
services:
  app:
    environment:
      - DB_HOST=db
      - DB_PORT=5432
```

aeo:
```aether
aeo_orchestration() {
    db_host = "db"
    db_port = "5432"
    
    app = container("app") {
        image("myapp:latest")
        // Environment passed via `aeo up` or shell env:
        // DB_HOST=db DB_PORT=5432 aeo up compose.ae
    }
}
```

**Alternative (secrets):**
```aether
import secrets (seal, unseal)

db_password = unseal("sealed-value-here")  // Decrypted at runtime
```

### 5. Port Mapping

Docker Compose:
```yaml
services:
  web:
    ports:
      - "80:8080"  # host:container
```

aeo: **Port mapping is future work** (driver is responsible; not yet in DSL).

**Workaround:**
- Use `localhost:8080` (no mapping; host reaches container's native port)
- Or use a reverse proxy container (add it to the composition)

### 6. Service Dependencies

Docker Compose:
```yaml
services:
  web:
    depends_on:
      db:
        condition: service_healthy
```

aeo:
```aether
db = container("db") {
    health("redis-cli ping")
}
app = container("app") {
    depends(db)  // Explicit reference
    health("curl localhost:8080/healthz")
}
```

**Key difference:** aeo blocks on *health*, not just "service started". The `depends(db)` edge means:
1. db boots first
2. aeo polls db's health until it passes
3. Only then does app boot

This is stricter than Compose's `depends_on` and prevents cascading failures.

### 7. Restart Policies

Docker Compose:
```yaml
services:
  app:
    restart_policy:
      condition: on-failure
      max_retries: 3
```

aeo: **Automatic restart is future work** (see `docs/research/` for discussions).

**Workaround:**
- Use supervisor (systemd, runit) to restart the entire composition
- Or manually: `aeo down ; aeo up` if something fails

### 8. Logging

Docker Compose:
```yaml
services:
  app:
    logging:
      driver: json-file
      options:
        max-size: 10m
```

aeo: **Logging is inherited from the driver** (podman/docker use their defaults).

**To view logs:**
```bash
aeo exec app-node docker logs container-id
# Or:
docker logs <container-id>
```

### 9. Multi-Compose to Multi-System

Docker Compose files are flat. aeo supports *nested* compositions (systems within systems).

Single Compose:
```aether
aeo_orchestration() {
    system("app") {
        db = container("db") { ... }
        web = container("web") { ... }
    }
}
```

Nested (aeo-agent will support distributed):
```aether
aeo_orchestration() {
    system("backend") {
        db = container("db") { ... }
        api = container("api") { ... }
    }
    system("frontend") {
        web = container("web") { ... }
    }
}
```

### 10. Migration Checklist

- [ ] Translate all `services` to `container()` (or `jail`, `bhyve_vm`)
- [ ] Translate all `healthcheck` to `health()`
- [ ] Translate all `depends_on` to `depends()`
- [ ] Translate all networks to `constrain{}` with `deny_egress()` / defaults
- [ ] Move environment variables to Aether code or shell env
- [ ] Identify workarounds for: volumes, port mapping, restart policies, logging
- [ ] Test composition: `aeo up`, `aeo status`, `aeo down`
- [ ] Add confinement: `limit{}` and `constrain{}` blocks
- [ ] Add image attestation: `attest("sha256:...")` for sensitive images

---

## Migration from Kubernetes

Kubernetes is fundamentally different from aeo (multi-host, declarative, HA). Migration is a conceptual shift, not a 1:1 translation.

### Key Differences

| Aspect | Kubernetes | aeo |
|--------|-----------|-----|
| Host scope | Multi-host (cluster) | Single-host (or agent-recursive, planned) |
| Config | Declarative YAML (all resources defined upfront) | Imperative Aether code (conditionals, loops, runtime decisions) |
| State model | Desired state vs actual state (reconciliation loop) | Live runtime (state machine per node) |
| Health | Liveness/readiness probes (soft) | Health-gated ordering (hard) |
| Orchestration | Kube scheduler + kubelet (distributed) | aeo runner (single process, or agent-recursive) |
| Confinement | Network policies (L3, CNI) + pod security policies | Portable (Linux cgroups/seccomp, BSD rctl/Capsicum/pf) |
| **Typical use case** | Large-scale HA clusters | Single-host confinement + integrity |

### When to Migrate

Migrate if:
- ✅ Your workload fits on one host (or a small agent fleet)
- ✅ You need portable confinement (Linux + BSD from one config)
- ✅ You want configuration-as-code (not YAML parsing)
- ✅ You prefer explicit over implicit (no hidden reconciliation loops)

Don't migrate if:
- ❌ You need HA/failover (Kubernetes does that; aeo doesn't)
- ❌ You need to scale to 100+ hosts (Kubernetes is designed for that; aeo-agent is planned)
- ❌ You rely heavily on CRDs and operators (aeo has no extension model yet)

### Migration Path

#### Step 1: Identify Portable Components

Not all Kubernetes resources are portable to aeo:

**Portable (map to aeo):**
- `Deployment` (stateless app) → `container` + `health`
- `StatefulSet` (stateful app) → `container` + data (via volumes, future)
- `Service` (internal) → implicit (aeo nodes reach each other by name)
- `ConfigMap` → Aether code (conditionals, env vars)
- `Secret` → `aeo secrets seal/unseal`
- `NetworkPolicy` → `constrain{} { deny_egress() / peer_egress() }`
- `LimitRange` / `ResourceQuota` → `limit{}` blocks

**Non-portable (out of scope for single-host migration):**
- `Ingress` (multi-host routing) → reverse proxy node (single-host alternative)
- `PersistentVolume` / `PersistentVolumeClaim` (cluster storage) → local volumes (future)
- `HorizontalPodAutoscaler` (dynamic scaling) → fixed composition (scale manually or via external orchestrator)
- `Namespace` (multi-tenancy) → separate compositions
- `RBAC` / `ClusterRole` (auth) → host-level access control (sudoers, etc.)

#### Step 2: Translate Deployment to Composition

Kubernetes Deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    spec:
      containers:
      - name: web
        image: myapp:1.0
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
        resources:
          limits:
            memory: 512Mi
            cpu: 500m
```

aeo composition:
```aether
import compose (system, container, health, limit, limit_memory, limit_maxproc)

aeo_orchestration() {
    system("app") {
        within(30s)
        web = container("web") {
            image("myapp:1.0")
            health("curl -f localhost:8080/health")
            limit("web") {
                limit_memory("512m")
                limit_maxproc(4)  // ~500m CPU = ~4 procs on 8-core
            }
        }
    }
}
```

#### Step 3: Translate ConfigMaps

Kubernetes ConfigMap:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: info
  DB_HOST: db
```

aeo (code-as-config):
```aether
aeo_orchestration() {
    log_level = env_or("LOG_LEVEL", "info")
    db_host = "db"
    
    app = container("app") {
        // Use env vars or bake into image
        // aeo doesn't have ConfigMap objects; config is code
    }
}
```

#### Step 4: Translate Secrets

Kubernetes Secret:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-password
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=  # base64(password123)
```

aeo:
```aether
import secrets (seal, unseal)

db_password = unseal("encrypted-value-here")
// Decrypt happens at composition runtime
```

To create the sealed value:
```bash
echo "password123" | aeo secrets seal > sealed-value
# Then paste into composition
```

#### Step 5: Translate NetworkPolicy

Kubernetes NetworkPolicy:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-policy
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: web
  egress: []  # Deny all egress
```

aeo:
```aether
db = container("db") {
    health("redis-cli ping")
    constrain("db") {
        deny_egress()  // No outbound; only peers can reach in
    }
}
```

#### Step 6: Multi-Node to Multi-Tier

Kubernetes Deployments are often distributed across nodes. On a single host, aeo arranges them in dependency order.

Kubernetes (replicated across 3 nodes):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: db }
spec: { replicas: 3, ... }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec: { replicas: 3, ... }
```

aeo (single-host, single replica per kind — scale by adding nodes):
```aether
aeo_orchestration() {
    system("app") {
        db = container("db") { ... }
        web1 = container("web-1") { ... }
        web2 = container("web-2") { ... }
        web3 = container("web-3") { ... }
    }
}
```

Or use a loop:
```aether
aeo_orchestration() {
    system("app") {
        db = container("db") { ... }
        i = 0
        while (i < 3) {
            web = container("web-${i}") { ... }
            i = i + 1
        }
    }
}
```

#### Step 7: Testing

Once translated:

```bash
aeo up compose.ae
aeo status        # Check all nodes are "up" and "healthy"
aeo audit         # Check attestation chain (if using attest())

# Test node communication:
aeo exec web-1 curl http://db:6379  # Should reach db
aeo exec db bash                      # Interactive shell

aeo down          # Verify teardown
```

### Migration Checklist

- [ ] Identify Kubernetes resources (Deployment, StatefulSet, ConfigMap, Secret, NetworkPolicy)
- [ ] Map them to aeo primitives (container, health, constrain, limit)
- [ ] Identify gaps (Ingress, HPA, RBAC, persistent storage)
- [ ] Decide: workaround (reverse proxy, manual scaling, host RBAC) or accept limitation
- [ ] Translate YAML to Aether code
- [ ] Extract Secrets and seal with `aeo secrets`
- [ ] Add `health()` probes for liveness/readiness
- [ ] Add `limit{}` for resource limits
- [ ] Add `constrain{}` for network policy and capabilities
- [ ] Test: `aeo up`, `aeo status`, node-to-node communication, `aeo down`
- [ ] Document any manual steps (scaling, failover, backup restore)

### Limitations & Workarounds

| Limitation | Workaround |
|-----------|-----------|
| No HA/failover | Use supervisor (systemd, etc.) to restart composition if it dies |
| No multi-host (yet) | aeo-agent (planned); for now, run separate compositions per host |
| No persistent volumes | Bake data into image, or use external storage (NFS, S3) mounted at boot |
| No horizontal scaling | Manually add nodes to composition + test; or use external autoscaler (CloudFront, etc.) |
| No Ingress | Add reverse proxy node (nginx, haproxy) to composition |
| No RBAC | Use host-level access control (sudoers, file permissions) |

### Example: Migrating a 3-Tier App from K8s

**Kubernetes (original):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: database }
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: postgres
        image: postgres:15
        env: [{ name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: db-secret, key: password } } }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: backend }
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: api
        image: myapi:1.0
        livenessProbe:
          httpGet: { path: /health, port: 5000 }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: frontend }
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: web
        image: myapp:1.0
        livenessProbe:
          httpGet: { path: /health, port: 3000 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-policy }
spec:
  podSelector: { matchLabels: { app: database } }
  policyTypes: [Ingress, Egress]
  egress: []
```

**aeo (migrated):**
```aether
import compose (system, container, health, depends, limit, constrain, deny_egress)
import secrets (unseal)

aeo_orchestration() {
    system("three-tier-app") {
        within(30s)
        
        // Secrets
        db_password = unseal("AgBFa2C...xyz")  // Run: echo "password" | aeo secrets seal
        
        // Database tier
        db = container("postgres") {
            image("postgres:15")
            health("pg_isready -U postgres")
            limit("db") { limit_memory("1g") }
            constrain("db") { deny_egress() }  // DB never phones home
        }
        
        // Backend tier (depends on db, confined)
        api = container("api") {
            image("myapi:1.0")
            depends(db)  // db must be up + healthy first
            health("curl -f localhost:5000/health")
            limit("api") { limit_memory("512m") }
            constrain("api") { deny_egress() }  // API only reaches db + peers
        }
        
        // Frontend tier (depends on api)
        web = container("web") {
            image("myapp:1.0")
            depends(api)
            health("curl -f localhost:3000/health")
            limit("web") { limit_memory("256m") }
            // web can reach internet (not confined)
        }
    }
}
```

Then:

```bash
aeo up compose.ae
aeo status    # All three should be "up"
aeo audit     # Verify integrity (if using attest())
aeo down      # Teardown in reverse order
```

## Summary

- **From Docker Compose:** Straightforward 1:1 mapping; aeo is stricter on health-gating
- **From Kubernetes:** Conceptual shift; aeo is single-host/agent-recursive, not multi-host HA
- **Key gains:** Portable confinement, configuration-as-code, explicit ordering, health-gated bring-up
- **Key losses:** HA/failover (for now), native multi-host (aeo-agent pending), dynamic scaling

Choose aeo if you value correctness and confinement over scale and HA; Kubernetes if you need the opposite.
