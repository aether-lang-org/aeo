# aeo examples — the substrate grid

Each `silly_addition_*.ae` here is the **same two-tier app** — a `db` cache (redis)
and an `app` that serves `/add/N/M` over HTTP, `app` depending on `db` — deployed
on a **different substrate**. The core six span the orchestration matrix —
**with/without a VM (VMM)** × **with/without containers (podman)**, plus the
host-native isolation tiers (Linux LXC, FreeBSD jails) — across both host OSes
aeo targets. A seventh (`confined`) layers the confinement vocabulary on top.

They're deliberately the *same workload* so the only thing that varies is the
substrate (or the confinement) — read any one, then diff it against another to
see exactly what a different backend, or turning on `constrain{}`/`limit{}`,
changes.

## The grid

| Demo | Host | VM | Container | Cell |
|---|---|---|---|---|
| `silly_addition_bhyve_podman.ae` | FreeBSD | bhyve VM | podman (inside) | **+VMM +podman** |
| `silly_addition_kvm_podman.ae`   | Linux   | KVM VM   | podman (inside) | **+VMM +podman** |
| `silly_addition_kvm.ae`          | Linux   | KVM VM   | —               | **+VMM −podman** |
| `silly_addition_containers.ae`   | Linux   | —        | podman (host)   | **−VMM +podman** |
| `silly_addition_lxc.ae`          | Linux   | —        | LXC (system)    | host-native isolation (Linux) |
| `silly_addition_jails.ae`        | FreeBSD | jail     | —               | host-native isolation (FreeBSD) |

`−VMM −podman` is **not** a cell — a compute node has to run *somewhere*, so "no
VM, no container" is degenerate.

A seventh demo, **`silly_addition_confined.ae`**, is *not* a new substrate cell —
it's the `containers` cell with the **confinement** vocabulary turned on
(`limit{}` caps + `constrain{}` + `deny_egress`), so it showcases the Linux
containment axes rather than another backend (see [Confinement](#confinement-the-impregnable-axis-live) below).

The naming is by SUBSTRATE (bhyve_podman / kvm / containers / jails), not the
workload. (The original demo was `silly_addition_cache.ae`; renamed for
consistency. Its internal `system("silly_addition_cache")` IDENTIFIER stays —
specs + ipam assert against that string.)

## What each demonstrates

- **bhyve_podman** (FreeBSD apex) — two bhyve VMs, each running a container,
  with the FULL confinement story: per-VM **Capsicum** fd grants + deny-default
  **pf** port policy. db answers 6379 to app only; a compromised redis can't
  exfiltrate. The richest demo.
- **kvm_podman** (Linux apex) — the direct analog: two KVM VMs each running a
  container. Caveat: the kvm arm boots `image()` as-is (no cloud-init
  provisioning like bhyve), so the guest images need podman+sshd+key baked in.
- **kvm** — bare KVM VMs (no container) — the VMM by itself.
- **containers** — two podman containers on the host, no VM — the most common
  real Linux deploy, and the Linux peer of the jails demo.
- **lxc** — two LXC *system* containers (a full-OS userland under its own root,
  via the classic `lxc-*` tools) — the Linux analog of a FreeBSD jail, distinct
  from the podman *app* containers.
- **jails** — two FreeBSD jails with **rctl** resource caps (exhaustion-DoS
  guard) — the host-native isolation tier.
- **confined** — the `containers` cell with all three Linux confinement axes on:
  `limit{}` → cgroup caps, `constrain{}` → cap-drop/seccomp, `deny_egress` →
  `--network none`. The showcase for "contain malware" on Linux.

## Confinement: the impregnable axis (live)

This is no longer a "future axis" — the Linux container confinement is **built
and live-proven**, from the *same* `limit{}` + `constrain{}` grammar that renders
to rctl/Capsicum/pf on FreeBSD (substrate-portable confinement):

- **cgroup caps** (the rctl peer) — `limit_mem`/`limit_maxproc` → `--memory`/
  `--pids-limit`. Proven: a fork-bomb inside a capped node is *refused*.
- **cap-drop / seccomp** (the Capsicum peer) — a `constrain{}` node →
  `--cap-drop ALL --security-opt no-new-privileges` (+`--read-only` on
  `deny_egress`).
- **network policy** (the pf peer) — `deny_egress` → `--network none` (no
  namespace; can't phone home); peer-only egress → an `--internal` podman net
  (reaches the declared peer, *not* the internet). This *sidesteps* the FreeBSD
  pf+if_bridge inter-VM bug entirely.

Plus, orthogonal to the demos but live: **image attestation** (`attest("sha256:…")`
refuses a mismatched image at boot, fail-closed) and a **tamper-evident audit
trail** (`aeo audit` verifies the hash chain). The FreeBSD demos carry the
FreeBSD side: Capsicum + pf (bhyve_podman, pf delivery pending the if_bridge
fix), rctl + the jail boundary (jails, live).

## Every demo is ALL-IN-ONE (self-contained, by design)

Each file BOTH declares the system AND verifies it — composition + operational
modes, nothing imported from a sibling spec. A shop writes thousands like these,
each standing alone. Two doors:

- **`aeo up examples/<demo>.ae`** — the front-door imports it as the
  `aeo_compose` module and calls `aeo_orchestration()`.
- **`ae run examples/<demo>.ae`** (with `AEO_MODE=...`) — runs `main()` → the
  rich `run_aeo()` door, asserting/deploying in place.

### Modes (env `AEO_MODE`, default `check`)

| Mode | What |
|---|---|
| `check` | (DEFAULT) data-model assertions only; no deploy. Runs ANYWHERE, instant. |
| `up`    | `aeo up`, leave it STANDING. No checks. |
| `smoke` | `aeo up` + a slim post-deploy HTTP check, leave it STANDING. (bhyve_podman, containers) |
| `suite` | `aeo up` + fuller checks, then TEAR DOWN. CI shape. |

```sh
# data-model check (anywhere, no backend needed):
AETHER_INCLUDE_PATH=$HOME/scm/aeocha ae run examples/silly_addition_jails.ae
# a live deploy (on the right host):
aeo up examples/silly_addition_containers.ae
```

The shared mode scaffold (`run_aeo`/`_mode_*`/the `_aeo_*` helpers) is repeated in
each file **on purpose** — these are self-contained, like every standalone program
repeating its own `main()`. **Do NOT** factor it into a common module: that breaks
the single-file property that is the whole point.

## Live-proven status (what's actually been run, not just modeled)

- **containers** — full `aeo up` → `2+2=4` over HTTP, *with the cross-container
  cache working* (a value poked into redis read back through app), live on
  Bazzite. `aeo down` verifies disappearance. The reference live deploy.
- **confined** — all three confinement axes enforced live: a fork-bomb refused by
  `--pids-limit`, a `deny_egress` node with no network namespace, cap-drop via
  `podman inspect`. The "impregnable" story, proven.
- **lxc** — `aeo up` → two alpine system containers RUNNING, `aeo exec db
  hostname` → `db` (contained), `aeo down` clean. Live on Bazzite.
- **kvm** — full `aeo up` booted two KVM VMs (rootless `-nic user`), alive +
  `aeo down`, live on Bazzite.
- **jails** — boot + jail-boundary containment + rctl caps, live on the GhostBSD
  box. The strongest FreeBSD live story.
- **bhyve_podman** — confinement data-model proven; live pf inter-VM *delivery* is
  the one BROKEN axis (TODO §1, the if_bridge bug — the Linux per-flow netpolicy
  sidesteps it).
- **kvm_podman** — check green; live `aeo up` needs guest images with podman+sshd
  baked in (honest caveat in the file header).

Also live on Bazzite: **image attestation** (a mismatched digest refused at
boot), the **tamper-evident audit trail** (an edited log caught by `aeo audit`),
and the **lifecycle ops** (snapshot/rollback round-trip on a container, prune
keep-N). All seven demos pass `check` standalone and build via both doors.

## Other examples here

- `recipe_realize/` — proves the `image_recipe` realizer end-to-end via `aeo up`
  (the golden-image build/clone path), separate from the substrate grid.
- `_parked/` — smaller single-tier demos (jail-only, vm-only, an all-Linux
  two-tier), strict subsets of the grid demos. Revive with
  `git mv examples/_parked/<x> examples/`.
