# examples/ review — element names & human clarity

A fresh-eyes review of the whole `examples/` tree post-redesign (pure compositions
+ `check()`/`smoke()`/`suite()` verbs): the 12 compositions, the 25 specs under
`checks/`, `silly_addition_app/`, and the README. Findings ordered by severity —
**A** is unambiguous drift/dead code, **B** is naming conventions needing a call,
**C** is structural observations to remember, not fix.

## A. Real defects (drift & dead code — fix)

### A1. `getenv` import style is a 3-way split

The worst naming inconsistency. The README's stated purpose is *"read one, diff
another"* — but diffing two examples shows import noise that isn't substrate:

| Style | Files |
|---|---|
| **No `std.os` import at all** + qualified `os.getenv()` | `lxc`, `nspawn` — compiles only *accidentally* (the front-door assembles them with the runner, which imports `std.os`, so qualified `os.*` resolves through the merge). Fragile. |
| `import std.os (getenv)` + bare `getenv()` | `firecracker`, `kvm`, `kvm_podman`, `windows`, `wslc` |
| `import std.os (getenv)` + **qualified** `os.getenv()` in helpers | `bhyve_podman` — a fourth micro-variant |

Post-#1009 (selective imports are additive) all forms work; one style should win.
The selective `import std.os (getenv)` + bare `getenv()` is the majority and the
ecosystem idiom.

### A2. Comment-vs-reality drift (headers promising what specs no longer do)

- `silly_addition_kvm_podman.ae:84` — *"suite: fuller post-deploy checks (HTTP)"*
  → `checks/kvm_podman_suite.spec.ae` has **zero** HTTP; it's a data-model
  re-assert.
- `silly_addition_windows.ae` + `silly_addition_wslc.ae` headers — *"the live
  probe reads the container hostname…"* → their suites don't probe hostnames
  anymore (that moved to "itest driver's job" in the migration). The promise
  survived; the probe didn't.
- `silly_addition_bhyve_podman.ae` `_guest_image()` comment — *"check-mode's tree
  snapshot… the env applies cleanly to every mode"* — "check-mode"/"every mode" is
  the dead `AEO_MODE` language. (The claim itself still holds — the model spec
  honors `AEO_GUEST_IMAGE` — only the phrasing is stale.)
- `silly_addition_confined.ae` header diagram labels db *"read-only"* — nothing
  in the declaration says read-only. The *renderer* adds `--read-only` on
  `deny_egress` (per the README), but as a tree label it reads like a declared
  attribute.

### A3. Dead imports

- `silly_addition_jails.ae` imports `smoke` from compose — never declares a
  `smoke()`.
- `checks/bwrap_suite.spec.ae` imports `std.os` — never uses it (leftover from
  the reverted #1009 workaround).

### A4. README staleness (`examples/README.md`)

- *"The core six span the matrix… A seventh, `bwrap`… One more, `confined`"* —
  that counting predates nspawn/firecracker/windows/wslc; there are 11 substrate
  rows now.
- Last line: *"builds via both doors"* — the second door (`ae run` + `AEO_MODE`)
  no longer exists. One door now: `aeo <phase> <file>`.

## B. Naming conventions — genuine judgment calls

### B1. `check()` runs `*_model.spec.ae`

Phase verb says `check`, filename says `model`. Defensible (verb = *when*,
filename = *what*), but a newcomer grepping "where's the check spec?" won't find
`*_check*`. Options: rename to `<name>_check.spec.ae`, or keep and document the
convention in a small `checks/README.md` — which doesn't exist and is worth
adding either way.

### B2. `limit("db")` placement is inconsistent

`confined` puts `limit("db"){}` **inside** `db = container("db"){}`; `jails` puts
it **outside**, as a sibling after the node. Both work — `limit`/`constrain` are
*name-keyed*, not block-scoped (that's why the name is repeated) — but the inside
placement misleads readers into thinking it's ctx-scoped like `health_retry(){}`.
One convention should win: outside is the honest one given the signature; inside
reads better. (The deeper wart — that `limit`/`constrain` require the name
repeated at all, unlike `health_retry()` which picks up `_ctx` — is a DSL
question beyond examples/.)

### B3. Dir name vs image tag

`silly_addition_app/` builds tag `localhost/aeo-examples/silly-add:latest` —
"silly_addition" vs "silly-add". Mild; a grep for the tag won't hit the dir name.

### B4. `AEO_FC_BUNDLEDIR`

The only env var that abbreviates its substrate (`FC`) where the others spell it
out (`AEO_LXC_IMAGE`, `AEO_NSPAWN_ROOTDIR`, `AEO_WSLC_IMAGE`).
`AEO_FIRECRACKER_BUNDLEDIR` would match the family. Full inventory, otherwise
consistent: `AEO_APP_IMAGE`, `AEO_APP_NIC`, `AEO_DB_IMAGE`, `AEO_DB_NIC`,
`AEO_GUEST_IMAGE`, `AEO_LXC_IMAGE`, `AEO_NSPAWN_ROOTDIR`, `AEO_WIN_IMAGE`,
`AEO_WSLC`, `AEO_WSLC_IMAGE`, `AEO_WSL_DISTRO`, `AEO_APP_HOST` (specs).

## C. Structural observations (flag, don't fix)

### C1. 9 of 11 suite specs are data-model re-asserts

Only `containers` and `bhyve_podman` suites probe anything live (HTTP); the other
nine re-run the same assertions as their `_model` spec. Each says so honestly in
comments, and the deploy→teardown lifecycle *is* the real value of `aeo suite`
there. But it means nine `_suite.spec.ae` / `_model.spec.ae` pairs are
near-duplicates to keep in sync. Worth remembering when live probes
(exec-into-node from a spec process) become possible.

### C2. `bhyve_podman` = `system("silly_addition_cache")`

The one file/system name mismatch. Documented in the README as deliberate
(specs + ipam assert on the string), so an accepted wart — but it's exactly the
row a newcomer trips on.

## D. DECIDED (2026-07-04): `container()` + `engine()`, lxc stays a kind

The B-section naming discussion resolved into a design. The deciding test:
**does every setter in the node block survive the engine swap unchanged?**
That's the promise `engine()` makes — change one string, nothing else.

| Node setter | podman | docker | wslc | lxc |
|---|---|---|---|---|
| `image(<OCI ref>)` | ✅ | ✅ | ✅ same ref pulls | ❌ wants a `dist:release` template |
| `expose(N)` | ✅ `-p` | ✅ `-p` | ✅ `-p` (live-proven) | ❌ no port-publish concept |
| `env(K,V)` | ✅ `-e` | ✅ `-e` | ✅ `-e` | ❌ nothing to map to |
| `command(...)` | ✅ | ✅ | ✅ | ❌ boots its OWN init |
| `health` via exec | ✅ | ✅ | ✅ `wslc exec` | ⚠️ lxc-attach, different semantics |
| `limit{}` | ✅ cgroup flags | ✅ | ✅ `--memory/--cpus/--ulimit` | ⚠️ different mechanism |

**The shape:**

- `container()` = the OCI app-container kind. New `engine("podman"|"docker"|"wslc")`
  property — **system-scope float + node override** (the same FluentSelenium float
  machinery as `within/every`). Auto default per host family: Linux → podman →
  docker; Windows → wslc → podman-through-WSL.
- `engine()` does **NOT** admit `lxc` — it fails the swap test on nearly every
  row (image namespace, expose, env, payload model). Putting it in `engine()`
  would make the property lie: a kind change wearing an engine costume. Same
  logic keeps `nspawn` (rootfs dir, machinectl) and `bwrap` (no image) as kinds.
- `docker()` and `wslc()` kind-verbs → deprecated aliases of
  `container(){ engine(...) }`.
- The `windows` kind **dissolves** (rather than being renamed): container-on-
  Windows is just `container()` with host-family engine resolution. The
  `silly_addition_windows`/`_wslc` examples collapse into "the containers demo
  deployed on a Windows host" — the substrate grid gets SMALLER while covering
  the same ground.
- **Bug this fixes en route:** the `docker` kind's dispatch is second-class TODAY
  — it goes through plain `up()` and silently loses the shared `aeo-<system>`
  network, `env()` pairs, and ALL `limit{}`/`constrain{}` rendering that
  `container` nodes get via `up_confined()`. Routing docker-pinned nodes through
  the one confined path removes the fork by construction.
- Naming rule extracted (from the `podman_container()`/`wsl_podman()`
  discussion): **name what's fixed by construction; parameterize what varies.**
  `wslc`/`firecracker`/`kvm` name their realizer because the realizer IS the
  tier; `container` stays generic because the engine varies; `wsl_podman` would
  have repeated the `podman_container` mistake one level down (a docker-in-WSL
  arm is a one-token driver change away).
- Motivating scenario: one Debian host with docker + podman + lxc, different
  systems on different runtimes —
  `system(A){ engine("docker") container(...) }` /
  `system(B){ container(...) }  // auto → podman` /
  `system(C){ lxc(...) }`. Caveat to surface loudly: podman and docker networks
  are separate planes; heterogeneous engines *within one* system can't resolve
  peers by name (published-port bridging only) — the runner should warn.

## E. General container nesting (the Proxmox docker-in-LXC pattern)

Ground truth from the homelab world (XDA, "How I run Docker in an LXC on
Proxmox", Jul 2025 — one of many): running an OCI engine **inside an LXC** is a
mainstream pattern, not an exotic one. Proxmox even ships community helper
scripts for it (`community-scripts/ProxmoxVE ct/docker.sh`). Why people do it:

- **Resource-starved hosts**: a decade-old laptop that can't run one GUI VM runs
  a dozen LXCs; docker-in-LXC gives container workloads without a VM's RAM/CPU
  overhead.
- **Device SHARING**: an LXC can share the host iGPU/PCIe across multiple
  consumers simultaneously; VM passthrough assigns the device exclusively. So
  the lxc tier is sometimes chosen *specifically* for nesting GPU workloads.
- The honest costs: weaker isolation than a VM; host (Proxmox) upgrades can
  break nested-docker LXCs; the privileged-vs-unprivileged fork (unprivileged =
  UID-0-mapped, safer, but CIFS/NFS mounts need privileged); LXC needs the
  nesting feature enabled (`nesting=1`).

**aeo already has the seam this generalizes over.** Today only the VM openers
(`bhyve_vm`/`kvm_vm`/`freebsd_vm`) set `curhost`, and the nested-container
bring-up hard-assumes a VM host (ipam IP + ssh:
`driver_vm.guest_container_up`). But every host-capable kind already exposes
`exec_capture` — lxc → `lxc-attach`, nspawn → `systemd-run --machine`, jail →
`jexec`, VM → ssh, container → `podman exec`. Nested bring-up IS "send the
child engine's commands through the host's exec seam" — the VM path is just one
instance. Generalizing:

1. Make `lxc()` (and `nspawn()`) block-host openers (set `curhost`, like the VM
   openers) so `lxc("dockerbox"){ container("web"){ engine("docker") } }`
   declares the Proxmox pattern directly.
2. Route nested bring-up by the HOST's kind: `get_kind(get_host(nm))` picks the
   exec transport (ssh / lxc-attach / machinectl / jexec) for the same engine
   command stream. One generalized `nested_container_up` over `driver_exec`
   instead of a VM-only special case.
3. The resident-agent path generalizes identically — an aeo-agent can live in an
   LXC as well as a VM (containment-correct: delegate in, report out).
4. Per-host-kind prereqs recorded, not hidden: lxc needs `nesting=1` (+
   privileged for NFS/CIFS volumes); the guest userland needs the engine
   installed (the same "seed installs podman" story as the VM path).
5. Nesting matrix = host-capable kinds × nestable kinds, each cell gated on
   "exec seam exists + child runtime can run there" — a compose-time validation,
   loud at `aeo check`, not a deploy-time surprise.

## What's good (for balance)

- The 12 compositions share a genuinely uniform skeleton: header (what/vs-siblings/
  honest-scope/prereqs/executor lines) → imports → `exports (aeo_orchestration)` →
  declaration → declared verification → helpers. Diffing works.
- "HONEST scope" sections are consistently candid about what each demo proves vs
  doesn't — rare and valuable.
- The `checks/` naming (`<name>_<phase-or-model>.spec.ae`) is fully regular; every
  spec re-declares the right system, all 25 pass standalone.
- `silly_addition_app/` cleanly holds the extracted app source with a build
  one-liner and the rationale.
- Env override pattern (`AEO_*` + helper-with-default) is applied everywhere it's
  needed.
