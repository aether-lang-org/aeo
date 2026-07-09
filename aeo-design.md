# aeo — design doc (as built)

The design of what aeo **is**, as implemented and live-proven (ae 0.364,
2026-07-09). An earlier version of this doc proposed a grammar and left two open
decisions; both are resolved and the grammar evolved in building it. This
describes the real system. For the user tour see [`README.md`](./README.md), for
the working surface see [`examples/`](./examples/), for the LLM primer +
footguns see [`LLM.md`](./LLM.md), for the honest per-item scorecard see
[`TODO.md`](./TODO.md).

## One paragraph

aeo is an **infrastructure orchestrator**: from a single Aether composition it
stands up, keeps coherent, confines, and tears down a deliberate *tree* of
compute nodes — FreeBSD jails + bhyve VMs, Linux podman/docker containers + LXC
system containers + KVM VMs. Bring-up is dependency-ordered and gated on
**health**; teardown is reverse-order and **verifies** disappearance. Its
purpose is the thing that distinguishes it from a generic orchestrator:
**trees of compute nodes that contain malware and are impregnable to attack** —
every node confinable (resource caps, cap-drop/seccomp, deny-default network),
attestable (image digest verified before boot, fail-closed), and audited
(tamper-evident hash chain). aeo is the third sibling to `aether` (the language)
and `aeb` (the build runner), built by aeb, shelling to aeb at runtime.

## Why aeo is separate from aeb (the load-bearing decision)

aeb has an architectural commitment that aeo's core feature *violates on
purpose*:

> **`build.dep()` is a runtime no-op.** The DAG is built entirely from textual
> extraction *before* any `.ae` file runs. Deps are data, not procedure. — aeb/LLM.md

aeb is **declare-then-schedule**: the graph is static text, grep-extracted,
topo-sorted, then nodes run as isolated subprocesses coordinating through
on-disk markers. A node cannot hold a runtime reference to another, let alone
block on its liveness.

aeo's signature feature is the exact opposite: a node comes up, and aeo **blocks
on its health** — a live reference, in one running process, with imperative
control flow (spawn, poll, block, proceed). That is sequencing + liveness *at
runtime*. Forcing it into aeb would smuggle procedure into a system whose key
invariant is "deps are data." Different grain ⇒ different tool.

| | aeb | aeo |
|---|---|---|
| grain | static DAG of artifacts | imperative orchestration of live nodes |
| dep | data (runtime no-op) | runtime reference (a node is live) |
| time | build-time | run-time lifecycle (up / healthy / confined / down) |
| invoke | `aeb target:name` | `aeo up compose.ae` |
| one-liner | "build the tree" | "stand the tree up, keep it coherent, contain it" |

**Do NOT let aeo grow aeb's graph features.** No static DAG, topo-sort, or build
cache in aeo — that work is aeb's; aeo shells out (`run_capture("aeb", …)`). The
moment aeo reimplements a static DAG it has become a second aeb and the factoring
rots. aeo's value is *only* the runtime + containment layer.

## The architecture, as built

### The compose DSL — config IS code

A composition is an ordinary Aether module exporting `aeo_orchestration()` (no
args). The kind is the verb; a trailing block configures it. It's real Aether —
control flow, env lookups, conditionals around the declarations. There is **no
config parser**: the composition is run, not parsed.

```aether
import compose (system, container)
import compose (image, health, depends, within, limit, limit_maxproc, constrain, deny_egress)
exports ( aeo_orchestration )

aeo_orchestration() {
    system("web") {
        within(30s)                                   // health-retry window for the tree
        db = container("db") {
            image("docker.io/library/redis:alpine")
            health("redis-cli ping")
            limit("db")     { limit_maxproc(32) }     // cgroup fork-bomb ceiling
            constrain("db") { deny_egress() }          // -> --network none
        }
        app = container("app") {
            image("docker.io/library/myapp:latest")
            health("curl -fsS localhost:8080/healthz")
            depends(db)                                // db up + healthy first
        }
    }
}
```

The DSL is closure-with-setters, **single-arg** (Aether is fixed-arity — repeat
the call for more), pure accumulation into a process-global KV (`std.config`).
`system(name){…}` opens a system; `container`/`jail`/`bhyve_vm`/… open nodes;
nesting (`bhyve_vm("x"){ container("app"){…} }`) records a containment edge
(`get_host`). The grammar is *substrate-agnostic*: a `kind` the host can't run is
a fast, loud error at eval time, not a silent no-op three nodes deep.

(History: the proposed grammar threaded a `cap` through every handle —
`jail(cap, "db")`, `aeo(cap)` — as capability injection. That is **not built**;
today's openers are `kind(name){…}` and `aeo_orchestration()` is cap-less. The
DI intent survives in spirit — the front-door grants the composition its
authority — but not as a literal `cap` parameter.)

### The runtime — one actor per node (Decision 2A, built)

Each declared node becomes one **Aether actor** (`Resource`) with a small
protocol: `Configure{nm, kind}` sets its identity → `Boot{}` drives
`driver_up` then a `within()`-bounded health poll → `Halt{}` drives
`driver_down`. State machine: `down → booting → up → failed`. Because `main`
cannot await an actor reply, the actor publishes its state through a **config-KV
state bridge** (`set_state`/`get_state`) that `main` polls — this is the
legitimate main↔actor channel, not a workaround.

Bring-up walks declaration order, spawning+booting each node whose deps are `up`,
blocking on health before proceeding. Teardown walks reverse order and — the
FluentSelenium `without()` twin — **verifies** each node is gone (probe until
absent), not merely flips a flag.

### The front-door — native supervision + codegen (Decision 1B, built)

`bin/aeo.ae` is native Aether (no bash trampoline). A real Aether constraint
shapes it: **actors are single-compilation-unit only** — `actor`/`message` defs
and their `spawn`/`!` sites must live in the file with `main` and do NOT cross
`import`. So the resource actor can't be a plain importable lib. The front-door
therefore **codegens by staging a build dir**:

1. copy `lib/` into a work dir;
2. install the operator's compose file as the `aeo_compose` module
   (it must define `aeo_orchestration()`);
3. copy `lib/aeo/runner.ae` (which holds the inlined actor + `main`) as the
   top-level `run.ae`;
4. `ae build run.ae --lib lib` → a composition binary;
5. run it under `os.run_supervised` (own process group, signal forwarding, group
   reap). A Ctrl-C during bring-up forwards to the whole tree; the operator then
   runs `aeo down` (Aether exposes no general in-process `sigaction`, so
   supervision is via the supervised-child model, not an in-process trap).

`examples/` files are the hand-written shape of that staged unit. On an immutable
host where `ae` isn't on the runtime PATH, an `ae` container-shim builds inside a
toolchain container (`docs/build-in-container.md`).

### Substrate independence (keep this true)

aeo's DSL/runtime layer is coupled to **nothing**. bhyve/jail are one substrate;
the same composition drives KVM, LXC, podman/docker — only the **leaf command**
changes per backend. `kind(...)` is a setter, never a hardcoded assumption; a
Linux-container node may `depends` on a BSD-jail node and the ordering layer does
not care about kernel. The unification is at the DSL + runtime layer; underneath
sit N per-backend drivers, each doing the load-bearing 80%: **idempotent up/down
+ a liveness probe**, genuinely different code per kernel.

"BSD **and** Linux from one composition" is real via (A) nested virt (aeo boots a
bhyve/KVM VM node, then runs a container *inside* it — the kernel boundary
crossed as one nesting edge; the `*_podman` demos do this, executing one level),
or (B) remote hosts via the resident agent (future — see Nesting). A single
single-kernel host can only *describe* both; only one kind boots there.

## The containment architecture (the purpose)

This is what aeo is *for*. Six axes; the design intent is that they share **one
substrate-portable grammar** that each driver renders to its host's mechanism.

### Two grammar blocks, two renderers

The operator writes the same `limit{}` and `constrain{}` blocks regardless of
substrate; the composition records them substrate-agnostically (`get_rctl`,
`get_constraints`, `get_netpolicy`); the driver renders:

| Grammar | FreeBSD renderer | Linux renderer |
|---|---|---|
| `limit{}` (caps) | `lib/rctl` → rctl rules | `lib/confine_linux` → `--memory`/`--pids-limit` (cgroups) |
| `constrain{}` grants | Capsicum fd grants | `--cap-drop ALL --security-opt no-new-privileges` |
| `constrain{}` netpolicy (`egress`/`deny_egress`) | `lib/pf` → pf anchor | podman network tier (`none` / `--internal` / shared) |

So a composition's confinement is **portable**: the driver picks the renderer.
`lib/confine_linux.confine_string2(rctl, constraints, netpolicy, …)` produces the
podman flag string; the runner splices it into `up_confined`.

### The six axes — design + live state

- **Resource caps (don't starve the host).** `limit{}` → cgroups (Linux) / rctl
  (FreeBSD). LIVE: a fork-bomb in a `--pids-limit 32` node is *refused*; rctl
  caps live on a GhostBSD jail.
- **Confinement (don't escalate).** `constrain{}` → cap-drop/seccomp (Linux) /
  Capsicum (FreeBSD, where bhyve self-confines). LIVE: `podman inspect` shows
  `CapDrop=ALL`.
- **Network policy (don't reach out).** `egress`/`ingress`/`deny_egress` →
  three Linux tiers (`--network none` for deny_egress; an `--internal` podman net
  for peer-only egress — reaches the named peer, not the internet; shared
  otherwise) / pf on FreeBSD. LIVE on Linux: a `deny_egress` node has no network
  namespace; a peer-egress node reaches its peer but not the internet. This
  **sidesteps** the one red axis below.
- **Image attestation (trust only what you pinned).** `attest("sha256:…")` →
  the driver verifies the image's actual digest before boot, **fail-closed**
  (an unresolvable digest is a refusal, not a skip), and runs `image@<digest>`.
  Three greppable states: `attested` / `unpinned` / `unattestable`. LIVE: a
  mismatched digest is refused at boot.
- **Audit trail (observe, tamper-evidently).** Every attest/confine decision is
  appended to a hash-chained log (`hash = sha256(prev + payload)`); `aeo audit`
  verifies the chain. LIVE: an edited entry is caught.
- **pf inter-VM network delivery (FreeBSD).** The one **red** axis: pf doesn't
  compose with `if_bridge` for inter-VM filtering (a known kernel bug). Rulegen
  is correct + unit-tested; live delivery is broken. The Linux per-flow netpolicy
  (routed/`--internal` networks, no bridge) is the design's answer and works.

### Nesting — the principle the post treats as defining

The grammar nests, the data model records containment, the preflight gates a
nested node against its guest substrate, and the nest **executes one level** (a
container inside a bhyve/KVM VM, built+run in the guest). What's not yet built is
*recursive, depth-agnostic* nesting. The design for that is **aeo-agent**
(`docs/aeo-agent.md`): rather than aeo reaching *through* a boundary (ssh-ing in
— the directionality the containment post calls a disaster), the container hands
its contained an agent; that agent carries orchestration deeper, receiving the
instructions for its node and everything below, and handing instructions to its
children's agents. Same actor protocol at every level, so no node knows its
depth — "further restricted without knowledge of its nesting depth."

## Day-2 operability (lifecycle & state ops)

Beyond up/down, aeo is operable like Proxmox *without becoming a platform* (no
web UI, no daemon, no HA — those cross the line). Verbs:
`snapshot`/`rollback`/`backup`/`prune` (ZFS for jail/bhyve via `lib/snapshot`;
podman-commit / qemu-img / lxc-snapshot for the Linux kinds via
`lib/snapshot_linux`), `exec`/`restart` (per-node), and enriched `status`
(per-node ip/caps/netpolicy/grants/attestation, `--json` for a CI gate). Each
substrate has its own honest semantics (kvm/lxc snapshots are offline; podman is
live) encoded in the driver.

## The seam to aeb

Boring on purpose: **artifacts on disk + a CLI invocation.** aeb produces an
image/disk in `target/<module>/`; aeo boots a node around it. Mid-composition aeo
can `run_capture("aeb", ["app:image"], env)` to build something it then deploys.
Not an in-process binding — the value-add over shell-out is unproven.

## Repo topology & invariants

```
~/scm/aether   the language; produces `ae`, `aetherc`, libaether.a
~/scm/aeb      build runner; built from Aether
~/scm/aeo      THIS repo; its own binary; built BY aeb (or `ae build`); calls aeb at runtime
~/scm/aeocha   the test framework aeo's specs use
```

- aeo's binary is emitted from THIS repo, never aeb's — putting it in aeb would
  drag infra backends (bhyve/jail/ssh/libvirt) into aeb's core and violate its
  "no domain-specific in core" rule. Edges: build-time + run-time aeo→aeb. **No
  cycle.**
- Link line is always `$(ae cflags)` — never hand-crafted `-I`/`-L`/`-laether`.
- **Ambient/cross-module state goes through `std.config`, never a module `var`**
  (the var path had cross-import soundness bugs aeo dodged only by this rule).
- aeo is substrate-agnostic at the core — never hardcode one backend as "the" one.

## What aeo is NOT

Not a build (it pulls images / `pkg install`s; it doesn't compile — shell out to
aeb). Not multi-host by default (every node is local until the agent/remote arm
lands). Not YAML — the composition *is* the config, full Aether underneath; don't
add a config-file parser, expose setters.

## Decisions, resolved

- **Decision 1 — front-door = 1B** (native Aether supervision + codegen). Built.
  The bash-trampoline alternative (1A) was rejected once `os.run_supervised`
  landed upstream.
- **Decision 2 — resource handle = 2A** (actor per node). Built. The plain-struct
  alternative (2B) was simpler to start but the actor model is what shipped and
  is proven across all drivers.

Both are settled; do not reopen or silently re-litigate.
