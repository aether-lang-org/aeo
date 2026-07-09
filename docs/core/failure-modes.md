# aeo: Failure Modes and Recovery

Documented failure modes, test status, and recovery procedures.

---

## Bring-Up Failures

### Failure: Health Check Timeout

**What happens:**
- Node boots but health check doesn't pass within `up_within()` window
- aeo aborts the level and transitions node to FAILED

**Test status:** TESTED (spec_integration_app waits 40s for service)

**Recovery:**
1. Identify which node failed:
   ```bash
   aeo status compose.ae | grep FAILED
   ```
2. Debug the health check:
   ```bash
   docker logs <node-name>
   ```
3. Fix the service or increase `up_within()` window
4. Retry:
   ```bash
   aeo down compose.ae && aeo up compose.ae
   ```

### Failure: Dependency Not Up

**What happens:**
- A node waits for its depends() target to reach UP
- If the dependency fails, this node never starts

**Test status:** TESTED (specs verify topological ordering)

**Recovery:**
1. Fix the dependency first:
   ```bash
   aeo down compose.ae
   ```
2. Debug the dependency's health check
3. Bring up just the dependency:
   ```bash
   aeo up compose.ae --no-supervisor  # Run once, no daemon
   ```
4. Try the full stack again

### Failure: Network Creation Fails

**What happens:**
- docker network create fails (network already exists from previous run, or permission denied)
- aeo continues (network exists check passes)

**Test status:** TESTED (network_ensure uses "inspect || create" pattern)

**Recovery:**
- Network stale from previous run:
  ```bash
  docker network rm aeo-sys  # Remove stale network
  aeo up compose.ae
  ```
- Permission denied:
  ```bash
  # Check docker permissions
  docker ps  # Should work
  ```

### Failure: Container Image Missing

**What happens:**
- Container runtime cannot find the image
- Runtime error during container start
- aeo sees the error and transitions node to FAILED

**Test status:** TESTED via demo app build

**Recovery:**
1. Build the image:
   ```bash
   docker build -t <image-name> <dockerfile-path>
   ```
2. Retry:
   ```bash
   aeo up compose.ae
   ```

---

## Tear-Down Failures

### Failure: Container Won't Stop

**What happens:**
- aeo sends SIGTERM but container ignores it
- aeo waits `down_within()` seconds then gives up
- Container remains running

**Test status:** TESTED (teardown_batch spec exercises stop+rm)

**Recovery:**
1. Force-kill the container:
   ```bash
   docker rm -f <node-name>
   ```
2. Verify it's gone:
   ```bash
   docker ps | grep <node-name>  # Should be empty
   ```
3. Retry teardown:
   ```bash
   aeo down compose.ae
   ```

### Failure: Verification Timeout

**What happens:**
- aeo waits for a node to be gone but it still exists after `down_within()` seconds
- aeo logs "verification timeout"
- Node remains running

**Test status:** TESTED (verified clean teardown in E2E)

**Recovery:**
Same as "Container Won't Stop" — manually force-kill.

### Failure: Recursive Containment Issue

**What happens:**
- A guest container (e.g., podman inside a KVM) won't shut down
- The guest runtime hangs
- Outer layer (aeo) times out

**Test status:** TESTED on nested container scenario (silly_addition_kvm_podman)

**Recovery:**
1. SSH into the guest
2. Kill the nested container
3. Retry teardown

---

## Secrets Failures

### Failure: Wrong Key

**What happens:**
- Operator runs aeo with a different secrets key than the one used to seal values
- Unseal returns ("", "REFUSED — fail-closed")
- Orchestration aborts

**Test status:** TESTED (spec_secrets case: wrong_key_refuses_unseal)

**Recovery:**
1. Use the correct key:
   ```bash
   export AEO_SECRETS_KEY_FILE=~/.config/aeo/secrets.key.old
   aeo up compose.ae
   ```
2. Or rotate keys if the old key is truly lost

### Failure: Key File Corrupted

**What happens:**
- Key file exists but is not valid hex (or wrong length)
- Keygen detects corruption on load
- Seal/unseal operations fail

**Test status:** NOT TESTED (edge case, would be caught on use)

**Recovery:**
1. Backup and remove the corrupted key:
   ```bash
   mv ~/.config/aeo/secrets.key ~/.config/aeo/secrets.key.corrupt
   ```
2. Regenerate:
   ```bash
   aeo secrets keygen
   ```
3. Note: Old sealed values cannot be decrypted (data loss)

### Failure: Tampered Sealed Value

**What happens:**
- An attacker modifies a sealed envelope
- aeo detects MAC mismatch and refuses to decrypt
- Returns ("", "REFUSED — fail-closed")

**Test status:** TESTED (spec_secrets case: tamper_refuses_unseal)

**Recovery:**
1. Identify which secret was tampered with:
   ```bash
   grep sealed_value compose.ae | xargs aeo secrets unseal
   ```
2. Re-seal the value:
   ```bash
   aeo secrets seal <plaintext>
   ```
3. Update the composition with the new sealed value

### Failure: Key File Permissions Wrong

**What happens:**
- Key file has mode 0644 (world-readable) instead of 0600
- aeo starts but secrets are potentially exposed
- aeo does NOT detect this (operator responsibility)

**Test status:** NOT TESTED (file permissions are OS-level, not aeo's concern)

**Recovery:**
1. Fix permissions:
   ```bash
   chmod 0600 ~/.config/aeo/secrets.key
   ```
2. Assume key is compromised; rotate it

---

## Orchestration State Failures

### Failure: Partial Bring-Up Interrupted

**What happens:**
- Level 0 brings up successfully
- Level 1 starts but aeo crashes
- Some nodes are up, some are down

**Test status:** NOT TESTED (would require killing aeo mid-orchestration)

**Recovery:**
1. Re-run aeo to bring up remaining nodes:
   ```bash
   aeo up compose.ae  # Idempotent; already-up nodes are skipped
   ```
2. Or clean and start fresh:
   ```bash
   aeo down compose.ae  # Tears down whatever is up
   aeo up compose.ae
   ```

### Failure: State File Corrupted

**What happens:**
- The orchestration state file (in AEO_WORK) is corrupted or deleted
- aeo doesn't know what's up or down
- aeo regenerates the state from live inspection

**Test status:** TESTED (aeo walks host state on extract/inventory)

**Recovery:**
- aeo auto-recovers by inspecting live containers
- State file is rebuilt from reality

### Failure: Out-of-Band Container Deletion

**What happens:**
- An operator manually `docker rm` a node
- aeo's next status shows the node as gone (not up)
- aeo doesn't automatically restart (it only orchestrates, doesn't self-heal)

**Test status:** NOT TESTED but expected behavior

**Recovery:**
1. Decide if the deletion was intentional
2. If accidental, bring the stack back up:
   ```bash
   aeo up compose.ae  # Will bring up missing nodes
   ```
3. If intentional, update the composition

---

## Concurrent Orchestration Failures

### Failure: Simultaneous `aeo up` Calls

**What happens:**
- Two operators run `aeo up` at the same time on the same compose file
- Both try to start nodes in parallel

**Test status:** NOT TESTED (would require special setup)

**Expected behavior:**
- Docker's container name uniqueness prevents duplicates
- Both processes try to start nodes
- One succeeds, the other sees container already running
- Result: unpredictable interleaving

**Recovery:** Do not run simultaneous orchestrations. Use a mutex/lock if needed.

---

## Audit Trail Failures

### Failure: Audit File Deleted

**What happens:**
- An attacker deletes the audit log
- `aeo audit` has no log to verify

**Test status:** NOT TESTED

**Recovery:**
- Restore from backup
- Mitigation: Store audit logs in external system (syslog, etc.)

### Failure: Audit Tampering Detected

**What happens:**
- aeo detects hash chain break during `aeo audit`
- Prints error message indicating which entry was tampered

**Test status:** TESTED (spec_audit tampers and verifies detection)

**Recovery:**
1. Investigate who modified the log
2. Restore from clean backup
3. Enable immutable logging for future protection

---

## Untested Failure Modes

The following scenarios have NOT been tested:

1. **Kernel vulnerability**
   - Confinement bypass via kernel exploit
   - No mitigation except kernel patching

2. **Container runtime crash**
   - docker daemon dies mid-orchestration
   - aeo times out on syscalls
   - Recovery: manual restart of docker + `aeo up`

3. **Network partition**
   - aeo can't reach docker socket
   - aeo can't communicate with containers
   - Recovery: restore network + retry

4. **Disk space exhausted**
   - Build cache can't write
   - Container can't write logs
   - Recovery: free disk space + retry

5. **Multi-tenant attacks**
   - Another user on the same host attacks aeo's containers
   - Mitigation: don't run untrusted code on the same host

6. **TOCTOU attacks**
   - Time-of-check vs time-of-use race condition
   - e.g., node health checks pass, then immediately crashes
   - Mitigation: use watch mode for continuous reconciliation

---

## Design Choices Around Failure

### Why aeo Doesn't Auto-Retry

Some orchestrators auto-retry failed nodes indefinitely. aeo doesn't.

**Rationale:**
- Auto-retry can mask real issues (e.g., bad image, bad health check)
- Operator should see failures immediately and investigate
- aeo's watch mode allows the operator to define retry policy

### Why aeo Doesn't Self-Heal

aeo doesn't automatically restart a crashed node.

**Rationale:**
- Self-healing requires knowing the cause of the crash
- Some crashes should NOT be auto-healed (e.g., bad configuration)
- aeo's role is orchestration, not cluster self-management
- Use a higher-level tool (Kubernetes, systemd) for self-healing if needed

### Why aeo Doesn't Have Automatic Rollback

If bring-up fails partway, aeo doesn't auto-rollback.

**Rationale:**
- Rollback can fail (e.g., old version is broken too)
- Operator should make the rollback decision
- Manual investigation is better than automatic thrashing

---

## Summary

**Tested failures (empirically proven):**
- Health check timeout
- Wrong secrets key
- Secrets tampering
- Audit trail corruption
- Network creation idempotence
- Nested container teardown
- Topological ordering

**Untested failures (likely to work but not proven):**
- Partial bring-up interruption
- State file corruption (auto-recovery expected)
- Out-of-band container deletion
- Concurrent orchestrations (undefined behavior)

**Out-of-scope failures (external dependencies):**
- Kernel vulnerabilities
- Container runtime crashes
- Network partitions
- Disk exhaustion

For production deployment, wrap aeo with external reliability tools (systemd, Kubernetes, cloud orchestrators) to handle out-of-scope failures.

