# mac exec — considered (with live findings)

**Status:** researched + primitives proven live on `macvm` (macOS 15.7.7,
x86_64). No driver built yet — this doc is the empirical basis for the API.

## What "mac exec" is (and is NOT)

macOS has **no native container primitive** — no cgroups, no namespaces, no jail
equivalent. Every "container on mac" (Docker Desktop, podman-machine, lima,
colima, and Apple's own `apple/container`) is really **a Linux guest in a VM**
with the container inside it. The isolation comes from the VM, not from macOS.

So a mac substrate that is *actually macOS* can't be an enclosure the way
`driver_lxc` / `driver_bsd` (jail) / `driver_nspawn` are. Instead:

> **mac exec** = the node's workload is a **native macOS process** run directly
> on the host. `sandbox-exec` (Seatbelt) is an **OPTIONAL policy filter** layered
> on that process — a permission-reducer, not an enclosure.

This mirrors aeo's existing split: the driver is the substrate (launch/observe/
reap a process); Seatbelt is a *confine* modifier (the mac peer of
`confine_linux`'s seccomp / FreeBSD Capsicum), NOT the substrate itself. A
mac-exec node runs plain unless a policy is opted into.

Naming it "mac exec" (not "driver_mac" / "mac container") keeps this honest: it
does not claim isolation it can't deliver.

## Live findings (macvm, 2026-07-22)

### `sandbox-exec` enforces real, partial confinement

`/usr/bin/sandbox-exec` is present out of the box (no install). Profiles are
Seatbelt S-expressions: `(version 1) (allow default) (deny <op>*)`.

| policy | result |
|---|---|
| `(deny network*)` | unconfined `curl https://example.com` → HTTP 200; confined → rc=6, `000` (couldn't connect). **BLOCKED.** |
| `(deny file-write*)` | confined `echo hi > $HOME/f` → `Operation not permitted`, rc=1. **BLOCKED.** |

So Seatbelt is a genuine permission filter (deny net / deny FS-write both hold).
It is Apple-"deprecated" as a public CLI but ships and works on 15.x; a
production driver should note that and keep the profile surface small.

### The substrate lifecycle works — death is observable AND classifiable

The aeo death-forensics contract needs: launch a node, know its pid, detect
death, and classify *why*. All hold for a native mac process:

| death mode | observed | verdict aeo can emit |
|---|---|---|
| clean self-exit `exit 42` | pid captured, `kill -0` liveness works, `wait` → **rc=42** | `exit(42)` |
| SIGKILL (OOM/kill analog) | `wait` → **rc=137** (128+9) | `signal(9)` / killed |

So mac exec can honor the same exit-vs-signal death vocabulary the other
substrates use (`lib/death`: exit / signal / oom / killed / verdict).

### CRITICAL: a sandbox violation does NOT kill the process

The most important semantic for the API: `sandbox-exec` **denies the operation
(errno) — it does not terminate the process.** A confined `curl` to a blocked
host returned rc=6 and *the process kept running* to completion. Contrast an
OOM-kill, which IS a substrate-level death.

Consequence for the driver: "policy violation" on mac is **app-level** (the
workload sees EPERM/failed syscalls), NOT a node death. The driver must NOT
report a Seatbelt denial as a death verdict — there's no death. This is unlike
seccomp `SCMP_ACT_KILL` (which *does* kill). A mac-exec confine profile shapes
what the workload *can do*, and the workload decides how to react.

## Sketch of the driver contract (to design, not yet built)

Mirror the driver interface (`up` / `down` / death-state), workload = a macOS
command:

- **up(node, cmd, [profile])** — launch `cmd` as a detached macOS process
  (optionally `sandbox-exec -f <profile> cmd`); record the pid. Health = the
  process is alive / a health command exits 0.
- **down(node)** — signal the pid; already-dead is success.
- **death-state(node)** — reap and classify: `exit(code)` vs `signal(n)`.
  Seatbelt denials are NOT deaths.
- **confine** — opt-in, off by default. Start from two canned profiles worth
  proving next: `no-network` and `read-only-fs` (both verified enforceable
  above). Plain if none requested.

## Not this substrate (separate mac directions)

- **apple/container** — Linux OCI containers, each in its own micro-VM via
  Virtualization.framework. A different substrate (the `driver_kata`/micro-VM
  family), and **arm64-only** — cannot run on this x86_64 macvm; needs Apple
  Silicon (Nic's M1) to prove.
- **mac → Linux VM (lima/colima/Virtualization.framework)** — full Linux guest,
  containers therein. The `driver_vm`/`driver_proxmox` family. Works on x86_64
  but is "containers in a hidden Linux VM," not mac-native.

These are real and worth their own evaluation; they are NOT "mac exec."
