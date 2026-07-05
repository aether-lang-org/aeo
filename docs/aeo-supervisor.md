# aeo-supervisor — the resident holder of this-boot's trees

Status: **BUILT + live-proven 2026-07-05** (ALL 7 substrate drivers: container, jail,
nspawn, bwrap, firecracker, lxc, kvm).
`lib/supervisor` (registry) + `bin/aeo-supervisord` (daemon, with a resident liveness
watch) + front-door adopt/release + the init-aware installer
(`bin/aeo-supervisor-install.sh`). Proven on CachyOS as a real systemd service:
installer → `active`; `aeo up` → adopted; `aeo down` → released via the supervisor; the
ORPHAN-GAP CLOSURE (down with an empty `.ae` still tears down what the supervisor
holds); the resident watch logs a held node that died. Proven SUBSTRATE-GENERAL across all
three holding-mechanism classes the daemon routes to: name-registry (container on
CachyOS, jail on FreeBSD via `driver_bsd`), the **systemd-unit registry** (nspawn on
CachyOS via `driver_nspawn` — adopt → `/status` alive → release), and the
**pidfile bare-process tier** (bwrap on CachyOS via `driver_bwrap` — the tier the
whole fallback discussion was about: adopt → alive → release, process gone), and the
**microVM tier** (firecracker on CachyOS via `driver_firecracker` — a real booted
Firecracker v1.16.1 microVM: adopt → `/status` alive → release → the fc process gone),
plus **lxc** (CachyOS via `driver_lxc`) and **kvm** (CachyOS via `driver_vm` — a real
qemu 11.0.2 microVM booting a cirros disk: aeo up boots+adopts, `/status` alive via the
pidfile, down releases → qemu gone). So the registry-holder holds and releases ALL 7
substrate drivers live, the same way. (Proving kvm surfaced a REAL daemon bug: the
`_driver_down`/`_driver_probe` router had no `kvm`/`bhyve` case, so those kinds fell
through to the container/podman default — a kvm node would be mis-probed dead + torn
down with `podman rm`. Fixed by adding driver_vm routing.) Remaining follow-ups (§8):
the OpenRC/Alpine installer arm live-proof, and supervisor-as-launcher (the deeper
pidfile removal — see §6, deliberately deferred).
NOTE the firecracker/nspawn `systemd-run --user` launch needs
`XDG_RUNTIME_DIR=/run/user/<uid>` in the environment — a bare (non-login) ssh session
lacks it and the `--user` unit silently fails to start.
Captures the decision to give aeo a host-resident supervisor so `aeo down`/`status`/
`watch` latch onto a live registry instead of re-deriving handles from a re-handed
composition (and so the pidfile fallback path can be deleted). Supersedes the "no
bespoke root daemon" lean in
TODO.md's hold-alive note — that note's reasoning is folded in below; the piece it
was missing is the *never-crash + boot-scoped + non-restoring* discipline, which is
what makes a small resident supervisor honest rather than a Terraform-state trap.

Read `docs/aeo-agent.md` first — the agent is the *per-guest deputy* (recursion
through the containment tree). The supervisor is a *different, complementary* thing:
the *host-level holder* of the whole tree. They compose (§7).

---

## 0. The problem it solves

Today `aeo up` builds the tree and the front-door **exits (rc 0)** — aeo leaves no
resident process in its own name. So `aeo down xyz.ae` has nothing of aeo's to latch
onto; it **re-derives** every substrate handle by re-running the composition:

- name-registry substrates (podman `NAME`, `jail -r NAME`, lxc, `systemctl … aeo-*`)
  → `down` re-computes the deterministic name and asks the *substrate's* registry;
- the bare-process tiers (bwrap, firecracker, the VM raw-launch fallback) have **no
  registry**, so aeo drops a **pidfile at a deterministic path** and `down` reads it
  back. This is the fallback codepath — a second-class path that exists only because
  nothing on the host *owns* those processes.

Two real costs:
1. **Fallback coding.** The pidfile path is a lesser, staleness-prone codepath
   (pid reuse; `kill -0` guards) that exists purely for want of an owner.
2. **The orphan gap.** `down` only tears down nodes in the composition you re-hand
   it. `up` a 3-node tree, edit the `.ae` to 2, `aeo down` → the removed node is never
   enumerated, so it lingers. (`aeo inventory`'s `DECLARED? no` column surfaces this;
   nothing closes it.)

A resident supervisor that **owns** every aeo-launched node closes both: it *is* the
parent, so it holds the handle (no pidfile), and it knows the full set it launched
(no orphan gap).

## 1. The shape (the decisions, settled)

- **Boot-scoped, non-restoring.** The supervisor starts **empty** on OS boot. It does
  NOT restore last-boot's trees — nothing is persisted to disk to restore. Trees come
  into being only via `aeo up` during this uptime; to get last-boot's systems back you
  re-run the `aeo up`s (an rc script or your own automation, if you want that).
- **Never crashes; if it does, reboot.** The supervisor is engineered as
  infrastructure, held to infrastructure reliability: do-one-thing, no untrusted
  input, no clever logic. Its failure is an **OS-level event** — ops restarts the box,
  not the daemon. This is a deliberate contract, and it BUYS the design's simplicity:
  no re-adopt / substrate-rescan path, no "daemon came back to a running-but-orphaned
  tree" case. The supervisor's lifetime == the useful lifetime of the trees it holds;
  they are born together (this boot) and die together (clean shutdown, or crash →
  reboot).
- **Supervisor, NOT datastore.** It holds the tree because it is the **parent** of
  every aeo-launched node (its own child processes / scopes) — the handles are LIVE,
  not records it wrote. There is **no `/var/lib/aeo/state.db`, ever.** This is the
  systemd model (holds units it started this boot), not the Terraform model (holds
  state it wrote to a file). Because it only ever knows things it is currently
  parenting, its memory cannot outlive — or lie about — the reality it describes.
- **`aeo up` hands the tree to the supervisor by default.** `--no-supervisor` (CLI)
  reverts to today's fire-and-exit, ephemeral behavior — the explicit opt-out, for CI,
  one-shots, and supervisor-less hosts.
- **Default `aeo up` with no supervisor present = ERROR, not a silent downgrade.**
  ("no aeo-supervisor on this host; start it, or pass `--no-supervisor`.") Consistent
  with aeo's dislike of fallback coding: default is supervised; the old way is
  available but you must *say so*.

## 2. What the supervisor is (and is NOT)

IS: a small resident process that holds, for this boot, the set of trees aeo stood
up — as live child handles — and answers a tiny protocol: `adopt` (take this
subtree), `release` (tear this down), `status` (what's held / is-it-alive), and hosts
the `watch`/reconcile loop over what it holds.

IS NOT: a process babysitter with a policy engine, a state store, a config parser, or
a reimplementation of systemd. It does not own reconcile *policy* (that's the
composition's `policy{}`, §item5); it hosts the *loop* and executes the drivers'
existing lifecycle verbs. The drivers still know how to bring a node up/down; the
supervisor just becomes the thing that HOLDS the resulting handle and the thing the
CLI talks to.

## 3. Cross-init portability (first-class constraint)

The supervisor must run on: **systemd Linux, non-systemd Linux (OpenRC/runit/s6/
sysvinit), the BSDs (rc.d), and Alpine (OpenRC + musl).** Two separable concerns,
per TODO.md's hold-alive note (the split it got right):

- **Install the supervisor itself** as a boot service, per the host's init:
  - **systemd** → `aeo-supervisor.service` (`Type=notify` or `simple`; NOT
    `Restart=always` — see below).
  - **OpenRC** (Alpine, Gentoo, non-systemd) → `/etc/init.d/aeo-supervisor` +
    `rc-update add`.
  - **runit / s6** → a service dir under the supervision tree.
  - **sysvinit** → `/etc/init.d/aeo-supervisor` LSB script.
  - **BSD rc.d** → `/usr/local/etc/rc.d/aeo_supervisor` + `sysrc
    aeo_supervisor_enable=YES`.
  This is the same init-matrix as the agent's TSR install (memory
  `aeo-agent-tsr-init-systems`) — share the renderer.
- **Hold the supervised NODES.** Here is where the never-crash decision simplifies a
  knot the old note struggled with. The old note wanted "adhere to each OS's
  supervisor for HOLD" (Quadlet on systemd, `daemon(8)` on FreeBSD, setsid fallback
  elsewhere) precisely because there was no aeo-owned holder. **With an aeo-supervisor
  that is itself the parent, the node-hold is uniform: the supervisor launches each
  node as its own child (a plain fork/exec it reaps, or a systemd transient scope it
  owns where available) and holds the handle directly.** No per-OS Quadlet/daemon(8)/
  setsid matrix for the NODES — only for installing the supervisor. The pidfile
  fallback isn't ported; it's deleted (the supervisor owns the pid natively).

### The `Restart=` question (why NOT auto-restart)

systemd `Restart=always` and FreeBSD `daemon(8) -r` would auto-restart the supervisor
on crash. **We do not want that** — it contradicts the "if it crashes, reboot"
contract and would resurrect a supervisor into a boot whose tree it no longer holds
(its children may have been reparented to init on its death). The supervisor is
`Restart=no` / no `-r`: a crash is terminal and surfaces as a down service the ops
team sees and responds to (reboot). This is the honest position the old note's
"native inits are uneven at restart-to-declared-state" observation was circling — we
sidestep it by not auto-restarting the supervisor at all, and by keeping RECONCILE
(the restart-to-declared-state work) in aeo's own `watch` loop, portably, exactly as
that note recommended.

## 4. `aeo up` / `down` / `status` / `watch` in supervised mode

- **`aeo up xyz.ae`** (default): build the composition (as today), then instead of the
  front-door itself launching + exiting, it hands the plan to the supervisor:
  `supervisor.adopt(system, plan)`. The supervisor brings each node up as its child,
  applies confinement/attest (the drivers' existing seams), and HOLDS it. `aeo up`
  returns rc 0 once the tree is up and adopted; the supervisor stays resident.
- **`aeo down xyz.ae`** (or `aeo down <system>`): ask the supervisor to `release` the
  system — it tears down exactly what it holds for that system, in reverse order,
  verify-gone. **No composition re-hand needed** in supervised mode (it knows the set),
  which is what closes the orphan gap. (Re-handing the `.ae` still works and is the
  path under `--no-supervisor`.)
- **`aeo status`**: query the supervisor for what it holds + per-node liveness.
- **`aeo watch` / reconcile**: the loop runs INSIDE the supervisor over the trees it
  holds — the resident home the reconcile work (§item1) always wanted. `policy{}`
  (§item5) still supplies the per-node cadence/on_drift.

## 5. What is deliberately NOT built

- **No cross-boot restore.** (§1 — by design; nothing persisted.)
- **No datastore / state file.** (§1.)
- **No supervisor auto-restart.** (§3.)
- **No policy engine in the supervisor.** Reconcile policy stays in the composition.
- **No reimplementation of systemd.** On a systemd host the supervisor may USE systemd
  transient scopes to parent nodes (it's already the pattern for nspawn/firecracker),
  but it is not a second init.

## 6. Honest consequences

- `aeo up` (default) **no longer exits into nothing** — it leaves a resident
  supervisor holding the tree. This is the "aeo becomes systemd-ish" shift the
  operator asked about; scoped exactly to *a live holder of this-boot's trees*, not a
  persistent state authority.
- A host must run the supervisor to use the default path; `--no-supervisor` is the
  escape hatch (and the only path on a host where you don't want a resident aeo).
- The pidfile fallback — HONEST SCOPE CORRECTION (2026-07-05, after building it): the
  supervisor removes the ORCHESTRATION-level fallback that motivated it — `aeo down`
  no longer re-derives node handles from a re-handed composition; it asks the
  supervisor, which holds the tree by its own record (proven: down with an empty `.ae`
  still tears the tree down). But the DRIVER-internal pidfile (in
  `driver_firecracker.down` / `driver_bwrap.down`) is NOT dead code — those drivers
  already prefer the name registry (`systemctl --user stop`) and fall back to a
  pidfile only on a host WITHOUT systemd-run. That per-substrate choice is a legitimate
  mechanism, not the fallback-coding complaint. TRULY eliminating the pidfile would
  require the supervisor to be the LAUNCHER of those bare-process tiers (fork/hold them
  as its own children) — a distinct, larger future item, not this one. So: the
  supervisor fixes the fallback the operator objected to (composition re-derivation);
  supervisor-as-launcher (the deeper pidfile removal) is deliberately deferred.

## 7. Relation to the aeo-agent

Orthogonal and composable:
- **agent** = per-GUEST deputy: carries orchestration *down through* a containment
  boundary (a container in a VM), because the host orchestrator must not reach
  *through* the boundary. It is the local orchestrator for its subtree, INSIDE the
  guest.
- **supervisor** = per-HOST holder: holds the whole tree of THIS host's nodes, so the
  CLI has something to talk to and `down` stops re-deriving handles from the
  composition (the orchestration-level fallback the operator objected to).

A nested tree uses both: the host supervisor holds the VM (and adopts it); inside the
VM, the agent is (in turn) that guest's local holder for its own children. Same
init-aware install renderer; same "hold live, don't persist" discipline.

## 8. Build sequencing (when this is chosen)

1. `aeo-supervisor` binary: the tiny resident holder + the `adopt/release/status`
   protocol (reuse `lib/transport_http` / `lib/protocol` — the agent's wire).
2. Init-aware installer (share the agent's TSR renderer): systemd unit / OpenRC /
   rc.d / runit — `Restart=no` everywhere.
3. Front-door: `aeo up` default → `adopt`; `--no-supervisor` → today's path;
   no-supervisor-on-default → error. `down`/`status` → supervisor.
4. Delete the pidfile fallback from the supervised path; move `watch` into the
   supervisor.
5. Live-prove on: a systemd box (CachyOS), a BSD (GhostBSD rc.d), and an Alpine/OpenRC
   host (the musl + non-systemd corner).
