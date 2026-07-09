# aeo: Operations Guide

Production deployment checklist and troubleshooting guide for aeo.

---

## Service Level Objectives (SLOs)

### aeo Latency SLOs

| Operation | Target | Measured (2-node) | Notes |
|-----------|--------|-------------------|-------|
| `aeo dry-run` | <1s | 0.44s | Validation only, no changes |
| `aeo up` | <5s | 1-2s | Depends on health polling + boot time |
| `aeo status` (warm) | <100ms | 45ms | After cache hits |
| `aeo exec` | <1s | 0.2-0.5s | Single command execution |
| `aeo down` | <5s | 0.44s | Orchestration only; Docker latency varies |

If any operation exceeds SLO:
1. Check if it's warm (cache hit) or cold (compile)
2. Measure subsystems independently (docker ps, ae build)
3. Identify bottleneck (compile time, health poll wait, or container latency)

### aeo Availability SLO

- aeo should be runnable whenever the container engine is available
- If `aeo doctor` reports NO engines, aeo cannot function
- If aeo crashes or hangs, manual intervention required (kill, check logs)

---

## Monitoring

### Health Checks for aeo Itself

Monitor these signals:

1. **aeo process alive**
   ```bash
   pgrep aeo-run || alert "aeo orchestration not running"
   ```

2. **Build cache freshness**
   ```bash
   [ -f ~/.cache/aeo/aeo-cli ] || alert "build cache missing"
   ```

3. **Secrets key present**
   ```bash
   [ -f ~/.config/aeo/secrets.key ] || alert "secrets key missing"
   ```

4. **Recent audit trail**
   ```bash
   find $AEO_WORK -name "audit.log" -mtime -1 || alert "audit trail stale"
   ```

### Health Checks for Orchestrated Nodes

Monitor via `aeo status`:

```bash
aeo status compose.ae --json | jq '.[] | select(.state != "up")'
```

Alert if any node is not in "up" state.

---

## Troubleshooting

### Problem: `aeo status` is slow (>1s)

**Diagnosis:**

1. Is it the first run (cold cache)?
   ```bash
   ls -l ~/.cache/aeo/aeo-cli
   # If missing or old, cache is cold
   ```

2. Is it waiting for health polls?
   ```bash
   aeo dry-run compose.ae  # Should be fast if plan is unchanged
   ```

3. Is Docker/podman slow?
   ```bash
   time docker ps -a  # Measure independently
   ```

**Fix:**
- Cold cache: Run `aeo status` twice. First is compile, second is fast.
- Slow health poll: Check if health check is hanging (docker inspect is slow)
- Slow docker: Upgrade Docker or check resource constraints

### Problem: `aeo up` hangs

**Diagnosis:**

1. Which node is hanging?
   ```bash
   aeo status compose.ae
   # Find the node in BOOTING state
   ```

2. Is the health check responsive?
   ```bash
   docker logs <container-name>
   # Check if the service is running
   ```

3. What is the configured health timeout?
   ```bash
   grep up_within compose.ae
   # Default is 30s; each level waits this long
   ```

**Fix:**
- Service not ready: Debug the container (docker exec, logs)
- Health check broken: Fix the health check command in the composition
- Timeout too short: Increase `up_within()` window

### Problem: `aeo down` doesn't verify disappearance

**Diagnosis:**

1. Are containers still running?
   ```bash
   docker ps --no-trunc | grep <node-name>
   ```

2. Is the verification timeout too short?
   ```bash
   grep down_within compose.ae
   # Default is 10s; increase if containers are slow to stop
   ```

**Fix:**
- Container doesn't stop: Manually `docker rm -f` and rerun `aeo down`
- Timeout too short: Increase `down_within()` window

### Problem: Secrets not decrypting

**Diagnosis:**

1. Is the key file missing?
   ```bash
   [ -f ~/.config/aeo/secrets.key ] && echo "key exists" || echo "MISSING"
   ```

2. Is the key corrupted?
   ```bash
   cat ~/.config/aeo/secrets.key | wc -c
   # Should be 65 bytes (64 hex chars + newline)
   ```

3. Was the key changed?
   ```bash
   md5 ~/.config/aeo/secrets.key
   # Compare against previous known hash
   ```

**Fix:**
- Missing key: Regenerate with `aeo secrets keygen`
- Corrupted key: Replace with backup or regenerate
- Key changed: Re-seal all values with the new key

### Problem: Audit trail verification fails

**Diagnosis:**

1. Has the audit log been modified?
   ```bash
   aeo audit compose.ae
   # If it fails, tampering is detected
   ```

2. When was it modified?
   ```bash
   stat $AEO_WORK/audit.log
   ```

**Fix:**
- Rollback to a clean state from backup
- Investigate who modified the log
- Enable immutable logging (forward to syslog)

---

## Scaling Considerations

### Batching Guarantees

aeo batches status probes: one `ps` per engine, not per node.

| Number of Nodes | Engines | Probes | Latency |
|-----------------|---------|--------|---------|
| 2 | 1 (docker) | 1 | ~45ms |
| 10 | 2 (docker + KVM) | 2 | ~100ms |
| 100 | 2 (docker + KVM) | 2 | ~150ms |
| 1000 | 2 (docker + KVM) | 2 | ~150ms |

**Implication:** Status latency scales with number of distinct engines, not number of nodes. Adding more Docker containers does not slow status.

### Limitation: Per-Node Health Polls

VMs and jails are probed per-node (no batching). Health polling latency scales linearly:

| VMs/Jails | Probe Latency |
|-----------|---------------|
| 1 | ~100ms |
| 10 | ~1s |
| 100 | ~10s |

Mitigation: Use container-based nodes for scale. VMs/jails are better for strong isolation, not high density.

---

## Key Rotation

If the secrets key is compromised:

1. Generate a new key:
   ```bash
   aeo secrets keygen  # Creates new ~/.config/aeo/secrets.key
   ```

2. Seal all secrets with the new key:
   ```bash
   for secret in $(list_all_secrets); do
     new_sealed=$(aeo secrets seal "$secret")
     update_composition "$secret" "$new_sealed"
   done
   ```

3. Revoke the old key:
   ```bash
   rm ~/.config/aeo/secrets.key.old
   ```

4. Rotate audit logs:
   ```bash
   mv $AEO_WORK/audit.log $AEO_WORK/audit.log.old
   ```

---

## Backups

Critical files to back up:

1. **Secrets key**
   ```bash
   cp ~/.config/aeo/secrets.key ~/.config/aeo/secrets.key.backup
   ```

2. **Audit trails**
   ```bash
   cp -r $AEO_WORK/audit.log /backup/audit.log
   ```

3. **Compositions**
   ```bash
   git clone (store in git)
   ```

Recommendation: Store secrets key in a KMS (HashiCorp Vault, AWS KMS, etc.). Store audit trails in a central log aggregator (syslog, Datadog, etc.).

---

## Limits and Quotas

aeo itself has no built-in limits, but the orchestrated nodes do:

- **Resource limits:** Set via `limit{} { ... }` in composition
- **Network limits:** Enforced by container runtime and OS
- **Confinement limits:** Enforced by kernel (cgroups, seccomp, rctl, pf)

To verify limits are enforced:

```bash
aeo status compose.ae --json | jq '.[] | {name, caps}'
# caps should show --memory, --pids-limit, etc.
```

---

## Disaster Recovery

### Scenario: All containers crashed

1. Investigate the crash:
   ```bash
   docker logs <container-name>
   ```

2. Check if it's a code issue or resource issue:
   ```bash
   docker stats <container-name>
   ```

3. Bring the stack back up:
   ```bash
   aeo up compose.ae --no-supervisor  # Skip supervisor, run once
   ```

### Scenario: aeo daemon hung

1. Kill it:
   ```bash
   pkill -f aeo-run
   ```

2. Clean up any partial state:
   ```bash
   aeo down compose.ae
   ```

3. Restart:
   ```bash
   aeo up compose.ae
   ```

### Scenario: Secrets key lost

**Unrecoverable without backup.** Mitigation: Always back up the key in a KMS.

If lost and no backup:
1. Delete all sealed values (data loss)
2. Generate a new key
3. Reseal all values
4. Revert the orchestrated state (containers know their old secrets, which are now invalid)

---

## Compliance and Auditing

### Audit Trail Format

Each line in the audit log contains:
```
timestamp | actor | action | resource | result
```

Example:
```
2026-07-09T12:00:00Z | user | SEAL | db_password | success
2026-07-09T12:00:05Z | orchestrator | UP | db | health_passed
2026-07-09T12:00:10Z | orchestrator | UP | app | health_passed
```

### Verification Script

Run regularly to detect tampering:

```bash
aeo audit compose.ae && echo "Audit trail verified" || echo "TAMPERING DETECTED"
```

### Compliance Checklist

- [ ] Audit trails stored in central log (immutable)
- [ ] Secrets key backed up in KMS
- [ ] Access logs reviewed regularly
- [ ] Confinement policies documented
- [ ] Security updates applied within SLA

