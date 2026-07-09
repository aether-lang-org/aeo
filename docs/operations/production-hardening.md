# aeo: Production Hardening Checklist

This guide prepares aeo for production deployment. Follow all sections before orchestrating sensitive workloads or exposing the host to untrusted network traffic.

## Pre-Deployment Audits

### 1. Host Kernel & Container Engine

**Requirement:** Versions within vendor support window.

- [ ] Linux kernel ≥ 5.10 (aeo tested on 5.15+; must support cgroups v2 for resource limits)
- [ ] FreeBSD ≥ 13.0 (aeo tested on 14.3; pf + bhyve required for network policy + VMs)
- [ ] podman ≥ 4.0 or docker ≥ 20.10 (must support `--security-opt` for seccomp, `--cap-drop`)
- [ ] Check vendor EOL dates: `uname -a`, `docker version`, `podman --version`

**Verification:**
```bash
uname -r  # Check kernel
podman --version  # Or docker version
```

### 2. Aether Runtime

**Requirement:** aeo requires ae ≥ 0.295 (handles actor string state correctly).

- [ ] `ae --version` reports 0.295 or later
- [ ] aeo binary is built from this version (check build log or `aeo doctor`)

**Verification:**
```bash
ae --version
aeo doctor
```

### 3. Ambient Network Policy

**Requirement:** Host firewall does not block containers/VMs from reaching each other.

On Linux:
- [ ] Check iptables: `sudo iptables -L FORWARD` should have a rule allowing container traffic or no restrictive rules
- [ ] Or use UFW: `sudo ufw status` — if enabled, allow docker/podman subnet (typically 172.17.0.0/16)

On FreeBSD:
- [ ] Check pf is not globally blocking: `sudo pfctl -s rules | head` (should show rules, not "No rules loaded")
- [ ] Check ipfw: `sudo sysctl net.inet.ip.fw.enable` should be 0 (disabled) unless you manage it explicitly

**Verification:**
```bash
# Linux
sudo iptables -L FORWARD | grep -E "ACCEPT|DROP"
# FreeBSD
sudo pfctl -s rules | wc -l
sudo sysctl net.inet.ip.fw.enable
```

## Security Configuration

### 1. Secrets Management

**Requirement:** Encryption keys are generated, stored, and rotated securely.

- [ ] Generate keys with `aeo secrets keygen` (not openssl; uses `random_hex` + atomic write + 0600 chmod)
- [ ] Store keys in `/etc/aeo/secrets/` (or equivalent, owner root, mode 0700)
- [ ] Backup keys to secure storage (HSM, encrypted volume, or vault) **before** deploying
- [ ] Document key rotation procedure (see below: Key Rotation)

**Verification:**
```bash
aeo secrets keygen > my-key
ls -l my-key  # Should show -rw------- (0600)
aeo secrets seal "hello" < my-key  # Should output ciphertext
aeo secrets unseal "ciphertext" < my-key  # Should output plaintext
```

### 2. Image Pinning & Attestation

**Requirement:** All node images are pinned to digest, not tag.

- [ ] Every `image()` block includes `attest("sha256:...")`
- [ ] Digests are obtained from `docker inspect myimage:tag` or registry API
- [ ] Digests are version-controlled (composition is committed with pins)
- [ ] Untrusted images use content-addressable caches (pre-pulled and verified)

**Bad (unpinned, vulnerable to tag rewrites):**
```aether
image("myapp:latest")
```

**Good (pinned, fail-closed):**
```aether
image("myapp:sha256:abc123...")
attest("sha256:abc123...")
```

**Verification:**
```bash
aeo doctor  # Reports attested vs unpinned nodes
```

### 3. Confinement Enforcement

**Requirement:** All untrusted or long-running nodes are confined.

For each node, apply:

- [ ] `limit{}` — resource caps to prevent fork-bombs/memory exhaustion
  ```aether
  limit("app") { 
      limit_maxproc(64)      // max 64 PIDs in this node
      limit_memory("512m")   // max 512MB RAM
  }
  ```

- [ ] `constrain{}` — capability drop + seccomp + network policy
  ```aether
  constrain("app") { 
      deny_egress()          // no outbound network
      // (Linux: becomes --cap-drop ALL; BSD: seccomp rules)
  }
  ```

- [ ] `deny_egress()` for any node that should not reach the internet
  ```aether
  constrain("db") { deny_egress() }  // Redis should not phone home
  ```

**Verification:**
```bash
aeo up compose.ae
aeo status --json | jq '.[] | {name, caps, netpolicy}'
# Each node should show caps (non-empty) and netpolicy (none / deny-egress / etc)
```

### 4. Network Policy Verification (FreeBSD)

**Requirement:** On FreeBSD, ipfw is disabled or managed, so pf rules bite.

- [ ] Check: `sudo sysctl net.inet.ip.fw.enable`
- [ ] If 1 (enabled), either:
  - Disable: `sudo sysctl net.inet.ip.fw.enable=0; sudo sysrc firewall_enable=NO`
  - Or use `AEO_IPFW_OFF=1 aeo up` to auto-disable (requires NOPASSWD sudo for sysctl)

**Verification:**
```bash
AEO_IPFW_OFF=1 aeo up compose.ae
aeo status  # Should show deny_egress nodes with no network
# Manual test: try to curl outside from a deny_egress node
aeo exec app-node curl google.com  # Should timeout/fail
```

### 5. Audit Logging

**Requirement:** Audit trail is enabled and tamper-evident.

- [ ] `aeo audit` shows a hash-chained log of all attest/confine decisions
- [ ] Audit log is written to persistent storage
- [ ] Audit log is backed up off-host or to immutable storage

**Verification:**
```bash
aeo up compose.ae
aeo audit  # Should show hash chain, no gaps
```

## Operational Readiness

### 1. Monitoring & Alerting

**Requirement:** Key metrics are monitored; failures surface immediately.

- [ ] aeo health-poll cycle time monitored (should be ~0.25s for 8 nodes; >1s is slow)
- [ ] Node up/down state changes trigger alerts
- [ ] Teardown failures (nodes stuck in "down" probing) trigger pages
- [ ] Secrets seal/unseal failures logged (MAC verification fail = tampering alert)

**Metrics to capture:**
```
aeo.orchestration.cycle_time_seconds  # Health poll latency
aeo.orchestration.nodes_up            # Count of "up" nodes
aeo.orchestration.teardown_verify_failures_total  # Count of unresponsive nodes
aeo.secrets.seal_errors_total         # Encryption failures
aeo.secrets.unseal_verify_fails_total  # MAC check failures (tampering)
```

**Tool integration:** Export to Prometheus/Grafana via shell scripts (example: `docs/operations-guide.md`).

### 2. Disaster Recovery

**Requirement:** Plan for node failure, host failure, secrets compromise.

**Node Failure:**
- [ ] Policy: acceptable downtime? (aeo keeps coherence; operator decides on remediation)
- [ ] Procedure: `aeo exec node-name bash` to debug, or `aeo down ; aeo up` to re-stand
- [ ] RTO estimate: typically <30s (rebuild + boot) unless image pull is slow

**Host Failure:**
- [ ] Backup composition to version control (already done if you commit `.ae` files)
- [ ] Backup secrets to secure vault (not in git)
- [ ] Recovery: rebuild host, restore secrets, `aeo up`
- [ ] RTO estimate: depends on image caches; with pre-pulled images, ~2min

**Secrets Compromise:**
- [ ] Immediate: rotate keys (see Key Rotation below)
- [ ] If sealed data was leaked: assume plaintext is compromised (re-key everything)
- [ ] Re-encrypt all sealed secrets with new key

### 3. SLO Targets

These are suggested; adjust for your deployment.

| Operation | SLO | Notes |
|-----------|-----|-------|
| `aeo up` (cached) | <0.5s | Binary already built, nodes pre-pulled |
| `aeo up` (cold) | <10s | Image pull dominates; adjust based on network |
| Health-poll cycle | <0.5s | Should batch via one `ps` per engine |
| `aeo down` (verify) | <5s | Proof of node absence |
| Secrets keygen | <10ms | Native implementation, no subprocess |
| Secrets seal/unseal | <5ms | HMAC-SHA256 + PRF-CTR, per node |

### 4. Capacity Planning

**Required capacity on host:**

- [ ] CPU: Nodes are lightweight; orchestration is <1% overhead (batched health polling)
- [ ] RAM: Depends on node workloads; aeo runtime is <50MB
- [ ] Disk: Composition binary cache (~10MB), secrets store (<1MB), audit log (grows ~1MB per week)
- [ ] Network: Health checks are ~100 bytes per cycle; external traffic depends on workloads

**Test capacity:**
```bash
# Baseline: run with current workload for 1 week, measure:
# - Peak RAM usage
# - Audit log growth
# - Health-poll latency trend (should be flat)
```

## Key Rotation

### 1. Generate New Key

```bash
aeo secrets keygen > /tmp/new-key
```

### 2. Re-encrypt Existing Secrets

For each sealed secret in your composition:

```bash
old_sealed="..."  # Current sealed value
old_plaintext=$(aeo secrets unseal "$old_sealed" < ~/.aeo/key)
new_sealed=$(echo "$old_plaintext" | aeo secrets seal < /tmp/new-key)
# Update composition with $new_sealed
```

Or use a helper script (under `docs/scripts/rotate-secrets.sh`):

```bash
./docs/scripts/rotate-secrets.sh \
  --old-key ~/.aeo/key \
  --new-key /tmp/new-key \
  --compose compose.ae \
  --output compose-rotated.ae
```

### 3. Verify & Deploy

```bash
aeo up compose-rotated.ae
aeo status
# If successful:
cp compose-rotated.ae compose.ae
mv /tmp/new-key ~/.aeo/key
chmod 0600 ~/.aeo/key
```

### 4. Revoke Old Key

Once all sealed secrets are migrated:

```bash
# Archive old key (don't delete; may be needed for forensics)
tar czf ~/.aeo/key-archive-$(date +%s).tar.gz ~/.aeo/key.old
# Then delete
shred -u ~/.aeo/key.old
```

## Compliance Checklist

### 1. Image Source Verification

- [ ] All images come from trusted registries (docker.io, quay.io, internal registry)
- [ ] Registries are authenticated (credentials in `/etc/docker/config.json` or equivalent)
- [ ] Image digests are verified before boot (`attest()`)

### 2. Secrets Storage

- [ ] Encryption key is ≥256 bits (aeo uses 256-bit random via `random_hex(32)`)
- [ ] Key is stored with mode 0600 (readable only by owner)
- [ ] Key is backed up to HSM or encrypted vault (not on the host alone)
- [ ] Key rotation happens at least annually (more frequently if compromise suspected)

### 3. Audit Trail

- [ ] Audit log is immutable (hash-chained; any edit is detected)
- [ ] Audit log includes all attest/confine decisions
- [ ] Audit log is archived for at least 90 days
- [ ] `aeo audit` can be independently verified

### 4. Network Confinement

- [ ] Every node has explicit network policy (deny_egress, peer_egress, or open)
- [ ] No node defaults to open network (fail-closed)
- [ ] Host firewall does not contradict node policy (aeo assumes host policy is permissive)

### 5. Access Control

- [ ] Compositions are version-controlled (GitOps)
- [ ] Only authorized users can run `aeo up`/`aeo down` (use `sudo` or CI/CD gating)
- [ ] Secrets are not in version control (`.gitignore` includes `.aeo/`)

## Troubleshooting

### "MAC verification failed" (unseal error)

Likely cause: sealed secret was modified in transit or key was rotated without re-encrypting.

**Fix:**
1. Verify the key matches the one used to seal: `aeo secrets unseal <value> < right-key`
2. If key was rotated: re-encrypt with new key (see Key Rotation)

### Health-poll cycle is slow (>1s)

Likely cause: one or more health checks are slow/hanging.

**Fix:**
1. Check health check command: `aeo status | grep health`
2. Manually run it: `aeo exec node-name <health-cmd>` — should complete <100ms
3. If slow: optimize the check (e.g., use `curl -m 1` with 1s timeout)

### Node stays in "down" state after `aeo down`

Likely cause: node did not respond to stop signal; verification loop timed out.

**Fix:**
1. Check driver logs: `aeo exec node-name systemctl status`
2. Force-kill: `sudo podman rm -f node-name` (or equivalent for your driver)
3. Re-run `aeo down` to re-verify

## Final Sign-Off

Before production deployment:

- [ ] All checks above completed
- [ ] Monitoring is active (metrics flowing to observability platform)
- [ ] Disaster recovery tested (restore from backup, verify it works)
- [ ] Capacity test passed (run for 1 week, peak metrics within limits)
- [ ] Security review completed (by team or external auditor)
- [ ] Documentation is up-to-date (runbooks, escalation procedures)

Sign-off:

```
Deployment Date: ___________
Authorized By: ___________
Witness: ___________
```

## Support & Questions

If you hit issues during hardening:
- Check `docs/core/failure-modes.md` for known failure modes + recovery
- Check `docs/operations/operations-guide.md` for SLOs and monitoring
- Check `docs/research/` for investigation journeys (how we debugged similar issues)
