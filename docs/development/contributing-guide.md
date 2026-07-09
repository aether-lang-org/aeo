# aeo: Contributing Guide

Welcome to aeo development. This guide covers adding drivers, new features, and fixes with the same standards as the core system.

## Core Principles

Before you write code, understand aeo's non-negotiables:

1. **Substrate independence at the core** — the DSL/runtime layer (`lib/aeo/runner.ae`, `lib/compose/`) is agnostic to bhyve/Linux/KVM. Only drivers (`lib/driver_*`) know their substrate.
2. **State machine invariants** — nodes cycle `down → booting → up` or `failed`. Every transition is explicit; no silent skips.
3. **Verified teardown** — `down` is not "mark as down"; it's "probe until the node is provably gone."
4. **Portable confinement** — `limit{}` and `constrain{}` are substrate-agnostic blocks. Drivers render them to cgroups/rctl/pf.
5. **Fail-closed secrets** — encryption is encrypt-then-MAC, MAC verification is constant-time, keys are 0600 on disk.
6. **No config parser** — the composition is executable Aether code, not YAML. Config IS code.
7. **Idempotency** — every `up` and `down` operation is idempotent. Running twice is the same as running once.

## Adding a New Driver

A driver is a per-substrate backend (`lib/driver_*`) that implements the driver protocol: `kind_present()`, `up_confined()`, `down_verify()`, `status()`. Example: Linux podman is `lib/driver_linux/module.ae`; FreeBSD bhyve is `lib/driver_vm/module.ae`.

### 1. Design the Driver Module

Create `lib/driver_newkind/module.ae` with:

```aether
import compose (system, container, node_attrs)
import std.os

// Detect if this substrate is available on the host
kind_present(kind: string) -> (present: int) {
    if kind == "newkind" {
        // Probe: can we run this kind? e.g., does the hypervisor/container engine exist?
        result = os.run_capture("which", ["newkind-cli"])
        return result.exit == 0 ? 1 : 0
    }
    return 0
}

// Bring a node up with confinement applied
up_confined(name: string, image: string, caps: string, constraints: string, netpolicy: string) -> (exit: int) {
    // 1. Parse constraints/caps/netpolicy (or accept them as already-rendered engine flags)
    // 2. Invoke newkind-cli to create and boot the node
    // 3. Apply confinement (resource limits, seccomp/capsicum, network policy)
    // 4. Return 0 on success, nonzero on failure (fail-closed: don't retry, don't continue)
    return 0
}

// Bring a node down and verify it's gone
down_verify(name: string, timeout_s: int) -> (exit: int) {
    // 1. Send stop signal to the node
    // 2. Poll until the node is provably gone (check driver's status, not just "I sent stop")
    // 3. Return 0 only when verified gone; timeout_s is the hard deadline
    return 0
}

// Probe node status (is it up, booting, failed, down?)
status(name: string) -> (status: string) {
    // Return one of: "up", "booting", "down", "failed"
    // This is called every health-poll cycle; keep it fast
    return "up"
}

// Optional: check node health (called after status==up to gate proceed)
health_check(name: string, cmd: string) -> (healthy: int) {
    // Run cmd inside the node; return 1 if healthy, 0 if not
    // This is the hook for "curl localhost:8080/healthz"; your driver executes it
    return 1
}
```

### 2. Integrate with lib/compose and Runner

The runner (`lib/aeo/runner.ae`) dispatches based on node `kind`:

```aether
if kind == "newkind" {
    result = driver_newkind.up_confined(name, image, caps, constraints, netpolicy)
}
```

Add this case to the `Configure` message handler in the resource actor. The DSL already supports your kind as soon as you:

1. Implement `kind_present()` to gate it
2. Add the dispatch in the runner
3. Add it to the compose lib (a single-arg opener):

```aether
// In lib/compose/module.ae
newkind(name: string) {
    // Emit a node of kind "newkind" with this name
    config.put("aeo.cfg.${name}.kind", "newkind")
}
```

### 3. Write Tests

Create `spec/spec_driver_newkind.ae` (example: `spec/spec_driver_linux.ae`):

```aether
import compose (system, container)
import aeocha (suite, test, assert_eq)
import driver_newkind

suite("driver_newkind") {
    test("kind_present detects newkind-cli") {
        present = driver_newkind.kind_present("newkind")
        assert_eq(present, 1, "should detect newkind")
    }

    test("up_confined creates a node") {
        exit = driver_newkind.up_confined("test-node", "test-image", "", "", "")
        assert_eq(exit, 0, "should succeed")
    }

    test("status reports node is up") {
        status = driver_newkind.status("test-node")
        assert_eq(status, "up", "node should be running")
    }

    test("down_verify stops and verifies") {
        exit = driver_newkind.down_verify("test-node", 30)
        assert_eq(exit, 0, "should stop and verify")
    }
}
```

Run with:

```bash
aeocha spec/spec_driver_newkind.ae
```

All tests must pass before a driver is considered complete.

### 4. Test End-to-End

Write a composition using your driver:

```aether
// examples/demo-newkind.ae
import compose (system, newkind, health, depends)

aeo_orchestration() {
    system("demo") {
        within(30s)
        app = newkind("app") {
            image("myapp:latest")
            health("newkind-cli inspect app | grep running")
        }
    }
}
```

Then:

```bash
aeo up examples/demo-newkind.ae
aeo status
aeo down
```

### 5. Document the Driver

Add a doc to `docs/development/`:

```markdown
# Driver: newkind

Implements orchestration of `newkind` nodes on [substrate description].

## Prerequisites

- newkind-cli ≥ 2.0
- Kernel modules: [list any]

## Confinement Implementation

- **Resource caps** (`limit{}`) → newkind-cli flags for memory/CPU/pids limits
- **Seccomp/grants** (`constrain{}`) → newkind-cli security options
- **Network policy** (`deny_egress`, etc.) → newkind-cli network flags

## Known Limitations

- [list any open issues]

## Testing

See `spec/spec_driver_newkind.ae`.
```

## Adding a Core Feature

A feature is something that affects the runtime or DSL (not just a driver). Examples: health-retry windows, snapshot/rollback, audit trails.

### 1. Design

Write a design doc (or ADR) in `docs/development/` explaining:
- **What problem does it solve?**
- **Why is it necessary?** (not nice-to-have)
- **Design trade-offs** — what's rejected and why?
- **Failure modes** — what can go wrong?

Example: `docs/development/design-aeo-agent.md` (the agent protocol).

### 2. Implement

Modify:
- `lib/aeo/runner.ae` (state machine, main loop)
- `lib/compose/module.ae` (DSL blocks)
- All drivers that need to support the feature
- `bin/aeo.ae` (CLI if needed)

### 3. Test

Add specs to `spec/spec_*.ae` that cover:
- **Happy path** — feature works
- **Failure cases** — feature fails gracefully (doesn't panic, rolls back)
- **Interaction** — feature works with other features (ordering + health, limits + multi-kind, etc.)

### 4. Update Documentation

- `docs/core/design-rationale.md` (add academic ref if applicable)
- `docs/operations/operations-guide.md` (add SLOs, monitoring, troubleshooting)
- `docs/core/failure-modes.md` (add failure modes + recovery)
- Examples (add a composition demonstrating the feature)

## Fixing Bugs

### 1. Reproduce

Write a minimal test case (spec file) that fails:

```aether
test("bug: ordering respects depends even with failures") {
    // This test currently fails; fix should make it pass
}
```

Commit this with message `test: add repro for [bug]` (test fails, intentionally).

### 2. Fix

Modify code to make the test pass. Commit with message `fix: [what was wrong]` (no "and" or "also"; one fix per commit).

### 3. Verify

- Run the test: `aeocha spec/spec_*.ae`
- Run end-to-end: `aeo up examples/*` / `aeo down`
- Check for regressions: run the full spec suite

## Code Style

### Aether

- **Naming:** `snake_case` for functions/vars, `CAPS_ONLY` for constants, `PascalCase` for types
- **Indentation:** 4 spaces (not tabs)
- **Comments:** Explain *why*, not *what*. The code shows what it does.
  ```aether
  // ❌ DON'T
  x = 10  // set x to 10
  
  // ✅ DO
  x = 10  // timeout in seconds (not milliseconds, for driver compatibility)
  ```
- **Error handling:** Fail-closed. No silent skips. If something can go wrong, it's an error.
- **No string interpolation in messages** — use logging/printf for debug, config KV for state

### Examples

- Keep them small (3-5 nodes max)
- Make them self-contained (no external images, or use public registries)
- Name them descriptively: `three-tier-app.ae`, `microservices-with-policy.ae`

### Documentation

- Use Markdown
- Explain *before* showing (narrative, then code)
- Link to other docs with `[name](path)` (relative paths)
- No trailing whitespace

## Review Process

1. **Fork or branch:** `git checkout -b feature/my-thing`
2. **Commit early, often:** One logical change per commit
3. **Write good commit messages:**
   ```
   feat: add newkind driver

   Implements kind_present, up_confined, down_verify, status for newkind.
   Tested against newkind-cli 2.0+; known limitation: no snapshot support yet.

   Closes #123.
   ```
4. **Run the spec suite:** All tests must pass
5. **Push and open a PR:** Include design doc link and test results
6. **Code review:** At least one approval before merge to main

## Release Criteria

Before aeo can be declared "world-class" for a new feature/driver:

- ✅ Code is in `main`
- ✅ All specs pass (100% coverage of happy path + failure cases)
- ✅ Documentation is complete (design + operations + failure modes)
- ✅ Examples exist
- ✅ Benchmarks measured (if performance-critical)
- ✅ No TODOs or FIXMEs in code

## Common Pitfalls

### 1. Silent Failures

❌ Don't:
```aether
result = os.run_capture("newkind-cli", ["create", name])
// Silently continue if it failed
```

✅ Do:
```aether
result = os.run_capture("newkind-cli", ["create", name])
if result.exit != 0 {
    panic("failed to create node ${name}: ${result.stderr}")
}
```

### 2. Substrate Assumptions in Core

❌ Don't:
```aether
// In lib/aeo/runner.ae
if os.platform() == "linux" {
    // Special case for Linux
}
```

✅ Do:
```aether
// In lib/driver_linux/module.ae
// Driver handles substrate-specific logic
```

### 3. No Config Parser

❌ Don't:
```aether
// Parse YAML from a file
yaml = read_yaml("compose.yml")
```

✅ Do:
```aether
// Composition IS code
import mycomposition
aeo_orchestration()  // It's a function call
```

### 4. Unverified Teardown

❌ Don't:
```aether
down_verify(...) {
    os.run_capture("newkind-cli", ["stop", name])
    return 0  // Assume it worked
}
```

✅ Do:
```aether
down_verify(...) {
    os.run_capture("newkind-cli", ["stop", name])
    timeout = now_seconds()
    while (now_seconds() - timeout < timeout_s) {
        status = status(name)
        if status == "down" {
            return 0  // Proven gone
        }
        sleep(100)
    }
    return 1  // Timeout waiting for verification
}
```

## Getting Help

- **Design questions:** Open an issue in the repo with the `design` label
- **Code review:** Tag maintainers in your PR
- **Bug reports:** Include steps to reproduce + host info (kernel, container engine version)

## Acknowledgments

Your contribution makes aeo world-class. Thank you.
