# aeo examples — the substrate grid

Each `silly_addition_*.ae` here is the **same two-tier app** — a `db` cache (redis)
and an `app` that serves `/add/N/M` over HTTP, `app` depending on `db` — deployed
on a **different substrate**. Together they span the orchestration matrix:
**with/without a VM (VMM)** × **with/without containers (podman)**, across both
host OSes aeo targets (FreeBSD, Linux).

They're deliberately the *same workload* so the only thing that varies is the
substrate — read any one, then diff it against another to see exactly what a
different backend changes.

## The grid

| Demo | Host | VM | Container | Cell |
|---|---|---|---|---|
| `silly_addition_bhyve_podman.ae` | FreeBSD | bhyve VM | podman (inside) | **+VMM +podman** |
| `silly_addition_kvm_podman.ae`   | Linux   | KVM VM   | podman (inside) | **+VMM +podman** |
| `silly_addition_kvm.ae`          | Linux   | KVM VM   | —               | **+VMM −podman** |
| `silly_addition_containers.ae`   | Linux   | —        | podman (host)   | **−VMM +podman** |
| `silly_addition_jails.ae`        | FreeBSD | jail     | —               | host-native isolation |

`−VMM −podman` is **not** a cell — a compute node has to run *somewhere*, so "no
VM, no container" is degenerate.

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
- **jails** — two FreeBSD jails with **rctl** resource caps (exhaustion-DoS
  guard) — the host-native isolation tier. The unblocked, live-proven path.

## Confinement coverage (honest)

FreeBSD demos carry real confinement: Capsicum + pf (bhyve_podman), rctl + the
jail boundary (jails). The **Linux container** demos do NOT yet apply Linux
confinement (seccomp/cgroups/netpolicy) — that's a tracked future axis
(TODO.md §5: the Linux peer of Capsicum/rctl/pf). The Linux demos today are about
the *orchestration* (build/run/depends/health), not the confinement.

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

- **jails** — boot + jail-boundary containment + rctl caps all proven LIVE on the
  GhostBSD box (2026-06-25). The strongest live story.
- **kvm** — the KVM arm's exact qemu invocation booted a daemonized VM on Bazzite
  (2026-06-26) — qemu-boot level proven; full `aeo up` pending prepared images.
- **bhyve_podman** — confinement data-model proven; live pf inter-VM delivery is
  BROKEN on the box's shared bridge (TODO §1, a known if_bridge bug).
- **containers / kvm_podman** — data-model (check) green; live `aeo up` on Bazzite
  is the next step (the build-in-container aeo + `ae` shim are set up — see
  `../docs/build-in-container.md`).

All five pass `check` standalone and build via both doors.

## Other examples here

- `recipe_realize/` — proves the `image_recipe` realizer end-to-end via `aeo up`
  (the golden-image build/clone path), separate from the substrate grid.
- `_parked/` — smaller single-tier demos (jail-only, vm-only, an all-Linux
  two-tier), strict subsets of the grid demos. Revive with
  `git mv examples/_parked/<x> examples/`.
