# aeo — design doc

Status: **design sketch**, pre-implementation. Written to capture the
shape of aeo and the decisions still open before the first commit. Sibling
to `aether` (the language), `aeb` (the build runner). Lives at `~/scm/aeo/`.

## One paragraph

aeo is an **infrastructure orchestrator**: a tool that stands up and tears
down a *deliberate tree* of VMs and containers — FreeBSD jails + bhyve VMs,
Linux LXC/Docker + KVM VMs — from a single Aether composition script run as
`aeo compose.ae`. It is **not** a build system and **not** an aeb SDK. It is
a third sibling tool, born already-spun-out (the way `aether-ui` and
`servirtium-vcr` ended up), built *by* aeb and able to shell *to* aeb at
runtime across a boring artifact + CLI seam. Its DSL philosophy is inherited
wholesale from the Aether ecosystem — **config IS code**, closure-with-setters,
no YAML/HCL parser — applied to live infrastructure instead of builds.

## Why aeo is separate from aeb (not an SDK inside it)

This is the load-bearing decision. aeb has a deep architectural commitment
that aeo's core feature *violates on purpose*:

> **`build.dep()` is a runtime no-op.** The DAG is built entirely from
> textual extraction *before* any `.ae` file runs. Deps are data, not
> procedure. — aeb/LLM.md

aeb is **declare-then-schedule**: the graph is static text, grep-extracted,
topo-sorted, then nodes run as isolated `_static` subprocesses coordinating
only through on-disk `.rc` markers. A node cannot hold a runtime reference to
another node, let alone block on its liveness.

aeo's signature feature — `vm(a).wait_for_it_to_be_up()` — is the exact
opposite: a **live handle, in one running process's memory, with imperative
runtime control flow** (spawn, poll, block, proceed). That is `state` +
sequencing + liveness *at runtime*. Forcing it into aeb would smuggle
procedure into a system whose key invariant is "deps are data, not
procedure." Different grain of computation ⇒ different tool.

### Division of labor, stated cleanly

|                   | aeb                                    | aeo                                          |
|-------------------|----------------------------------------|----------------------------------------------|
| Computation grain | Static DAG of build artifacts          | Imperative orchestration of live resources   |
| dep semantics     | Data (grep-extractable, runtime no-op) | Runtime references (`vm(a)` is a live handle) |
| Sequencing        | Topo-sort, then parallel subprocesses  | In-script control flow, `wait_for_*`, actors |
| Time model        | Build-time                             | Run-time / lifecycle (up, healthy, down)     |
| Invocation        | `aeb target:name`                      | `aeo compose.ae`                             |
| State             | `.rc` markers on disk                  | Live resource state in one process           |
| Honest one-liner  | "build the tree"                       | "stand the tree up and keep it coherent"     |

aeo is to infrastructure what aeb is to builds — **same DSL philosophy,
different time axis.** They rhyme deliberately, so an operator who reads
aeb's `.build.ae` grammar reads an aeo `compose.ae` instantly.

### Do NOT let aeo grow aeb's graph features

If aeo ever wants topo-sort / affected-target / build-caching, that work
*is aeb's* — aeo should shell out to aeb, not reimplement it. aeo's entire
reason to exist is the **runtime lifecycle layer aeb refuses to have**:
`wait_for_*`, health probes, ordering-by-liveness-not-by-artifact,
teardown-in-reverse. The moment aeo reimplements a static DAG, it has become
a second aeb and the clean split rots.

## Repo topology — aeo is its own repo, its own binary

```
~/scm/aether   the language; produces `ae`, `aetherc`, libaether.a
~/scm/aeb      build runner; its OWN binary; built from Aether
~/scm/aeo      orchestrator; its OWN binary; built BY aeb; calls aeb at runtime
```

**aeo is a second binary artifact — but NOT one produced in the aeb repo.**
Reasons:

1. **It violates aeb's own "no domain-specific in core" rule.** aeo is not a
   build SDK; it is a different domain (run-time infra lifecycle). Worse than
   domain-specific-to-aeb — it is off aeb's domain entirely.
2. **Dependency direction forbids it.** aeo is *built by* aeb and at runtime
   *shells out to* aeb. If aeo lived in aeb's repo, that repo would acquire
   conceptual + CI dependencies on `bhyve` / `jail` / `ssh` / `libvirt` —
   backends with nothing to do with building software. Separate repos keep
   aeb small and substrate-free; aeo carries the infra weight.
3. **Precedent.** `aether-ui` (was `contrib/aether_ui/`) and `servirtium-vcr`
   (was `std.http.server.vcr`) both spun OUT once they became their own
   thing, and now consume Aether the way external users do (install +
   `$(ae cflags)`). aeo should be born already-spun-out.

Edges: build-time aeo→aeb, run-time aeo→aeb. **No cycle** — aeb never
references aeo.

Nuance to avoid relitigating later: *"built by aeb"* is convenience, not
requirement. aeo can bootstrap with `ae build` directly (it is just an Aether
program) and adopt aeb for its own build later. The invariant is only that
aeo's binary is **emitted from the aeo repo**, by whatever builds it — never
checked into or produced by aeb's repo.

## The seam to aeb — "casually hand to aeb"

The handoff is the most boring, robust seam there is: **artifacts on disk +
a CLI invocation**, exactly how aeb already treats every external toolchain.

- **aeb → aeo**: an aeb build node produces an artifact (image, disk, jar),
  drops metadata in `target/<module>/`; the aeo composition picks it up and
  boots a resource around it.
- **aeo → aeb**: mid-composition, aeo shells out — `os.run_capture("aeb",
  ["app:image"], env)` — to *build* something it then deploys. aeb is just
  another binary aeo spawns.

(Forward-looking, not v0: aeb/LLM.md notes `--emit=lib` artifacts are now
first-class imports — a precompiled lib with reconstructed builder DSL. If
aeo ever wanted in-process rather than shell-out coupling, that mechanism
exists. Unproven value-add over shell-out; flagged, not adopted.)

## What aeo leans on from Aether (the language)

Catalogued so the design rests on real primitives, not wishes (see
aether/LLM.md):

- **config IS code** — the composition is a `.ae` the operator *runs*, not a
  YAML aeo parses. Reads like config; full Aether underneath (control flow,
  env lookups, conditionals). The "pseudo-declarative nirvana" pitch applied
  to infra. If anyone asks "add a YAML loader," the answer is the same as
  Aether's: no — expose setters, point at `docs/config-is-code.md`.
- **closure-with-setters DSL** — `vm(cap, "web") { image(...) memory(...) }`,
  identical idiom to aeb's `aether.program(b) { ... }` and Aether's
  `actor { ... }`. Single-arg-per-call setters (Aether is fixed-arity).
- **`os.run_capture`** — the canonical spawn+capture+exit primitive every
  backend driver shells through (argv-based, no shell, binary-safe).
  `os.run_pipe*` available if a backend needs a child→parent back-channel.
- **actor model** — `actor { state ... receive { ... } }` fits "a long-lived
  stateful resource you send messages to" almost too well (see Handle Model
  decision below).
- **std.http.client / os.run_capture** for liveness probes — `wait_for_*` is
  poll-until-`ssh` exits zero, or poll-until-`http.get` returns 200, with a
  timeout.
- **capability discipline** — `--emit=lib` capability-empty by default; host
  injects authority via the `cap` handle (see Front-Door decision). This is
  what makes running a not-fully-trusted `compose.ae` defensible: it can only
  touch backends `cap` grants.

## Substrate independence (important — keep this true)

aeo's DSL/graph layer is coupled to **nothing**. bhyve/jail are one substrate;
the *same composition tree* drives KVM/libvirt, LXC/Docker/Podman, QEMU, even
cloud CLIs — only the **leaf command** changes per backend. So:

- `kind(...)` / `backend(...)` is a setter, never a hardcoded assumption.
- A Linux-container node may `dep` on a BSD-jail node; the ordering layer does
  not care about kernel.
- "BSD **and** Linux from one script" is real via either **(A) remote hosts**
  (each node's builder `ssh`-es its target host — aeo is a control plane) or
  **(B) nested virt** (aeo boots a bhyve Linux VM node, then creates LXC
  *inside* it — kernel boundary crossed as one `dep` edge). (C) single-host /
  single-kernel can only *describe* both; only one kind boots — the trap.

The unification is at the **graph + DSL layer**; underneath sit N
per-backend drivers. The DSL is the easy 20%; the load-bearing 80% is each
backend's **idempotent up/down + liveness probe** — genuinely different code
per kernel. Unified DSL is real and worth building; it does not erase the
drivers.

The one thing that *would* weld aeo to FreeBSD: leaning on **hierarchical
jails as a native kernel tree** (jails creating sub-jails). If the tree's
recursion lives there, it is FreeBSD-locked. If "tree" just means a
boot-order DAG, it stays portable. Decide per-composition, not in the tool.

## Host adaptation & capability-gated grammar

aeo **adapts to whether the host is BSD or Linux**, and some grammar must
**fast-fail when the host can't honor it** (the headline example: requesting
Capsicum containment on a Linux host, or on a FreeBSD kernel lacking it).
Three rules:

1. **Detect once, at startup, in the front-door.** aeo probes the host
   (`uname -s`, plus capability probes — see below) and stamps a host-profile
   onto the injected `cap`. Every handle (`jail`/`vm`/`container`) reads the
   profile from `cap`; no driver re-probes ad hoc.
2. **Backend availability gates which `kind(...)` values resolve.** `kind("jail")`
   / `kind("bhyve")` require FreeBSD; `kind("lxc")` / `kind("kvm")` require
   Linux. A `kind` the host can't execute is a **fast, loud error at
   composition-evaluation time** — before any resource is touched — not a
   silent no-op and not a runtime failure three nodes deep. (Remote/nested-virt
   targets gate on the *target* host's profile, not the orchestrator's.)
3. **Capability features (Capsicum, Casper) gate on a runtime probe, not just
   on `uname`.** "FreeBSD" ≠ "Capsicum present" — a kernel can lack it. So the
   gate is a positive probe (`available() == 1`), with a deliberate choice per
   feature between *fast-fail* (the operator asked for enforcement they can't
   get) and *degrade-with-warning* (best-effort containment).

### This is already designed in Aether — reuse it, don't reinvent

The `feat/freebsd-sandbox-parity` branch (see below) **already implements the
exact portability contract** aeo wants, at the language layer:

- `std.capsicum.available() -> int` — 1 if Capsicum is usable *right now*, 0
  off FreeBSD or on a kernel without it. Its own docstring says *"Portable code
  should branch on available() before relying on enforcement."* That IS aeo's
  fast-fail gate; aeo inherits it rather than writing host-detection for
  Capsicum.
- `capsicum.enter()` returns `CAP_UNSUPPORTED` (-2) off FreeBSD — every call
  degrades cleanly, never crashes.
- `std.casper.available()` — same shape for the DNS/passwd/sysctl delegation a
  Capsicum-sandboxed process needs.
- Runtime dispatch precedent: `spawn_sandboxed_{linux,bsd,stub}.c`,
  self-guarded by `#if defined(__FreeBSD__)/__linux__`, with the **stub that
  fails loudly** (`"only available on Linux and FreeBSD"`, returns -1). aeo's
  backend drivers should mirror this three-way split exactly:
  `driver_bsd` (jail/bhyve) / `driver_linux` (lxc/kvm) / `driver_stub`
  (fail-loud).

So aeo's host-adaptation = (a) a thin `uname`-based backend selector for
*which kind runs where*, layered over (b) Aether's already-built
`available()`-probe contract for *capability features*. aeo writes (a); aeo
consumes (b).

### Fast-fail vs degrade — the per-feature call

Stated so it isn't decided ad hoc per driver:

| Grammar | Host lacks it → |
|---|---|
| `kind("jail")` / `kind("bhyve")` on Linux | **fast-fail** at eval — wrong substrate, operator intent is unambiguous |
| `kind("lxc")` / `kind("kvm")` on BSD | **fast-fail** at eval — same |
| `require_capsicum()` (operator asked for enforcement) | **fast-fail** if `capsicum.available()==0` — they asked for a guarantee the host can't give |
| `prefer_capsicum()` / best-effort containment | **degrade + warn** — run unsandboxed, audit-log that enforcement was unavailable |

The split is: *did the operator request a **guarantee** or a **preference**?*
Guarantee → fast-fail. Preference → degrade with a loud, audited warning
(`std.audit` from the same branch is the natural sink for "enforcement
requested but unavailable").

## Sketch of the surface (illustrative, not final)

```
// compose.ae  — run with `aeo compose.ae`
aeo(cap) {
    db  = jail(cap, "db")        { dataset("tank/db") ... }
    web = vm(cap, "web")         { image("freebsd-14.ova") depends(db) ... }
    k8s = container(cap, "k8s")  { host("linux-box") kind("lxc") depends(web) ... }

    db.up(); web.up(); k8s.up()
    web.wait_for_it_to_be_up()   // poll ssh/http until healthy, with timeout
}
```

`cap` threads through every handle — the script *receives* authority to spawn
`bhyve`/`jail`/`ssh`, it does not construct it. Mirrors aeb's `aeb(cap)`
entrypoint convention exactly.

## Upstream dependency: the `feat/freebsd-sandbox-parity` Aether branch

aeo's Capsicum/host-gating story rests on an **existing but unmerged** Aether
branch: `feat/freebsd-sandbox-parity` (GitHub: aether-lang-org/aether).
Assessment (from reading the branch, not the name):

**It is far more complete than "stale draft" suggests** — ~1826 insertions
atop v0.166.0, clearly authored by someone who understood Capsicum properly:

- `std.capsicum` — bindings (`available`/`enter`/`in_mode`/`rights_limit`/
  `fcntls_limit`, full `R_*`/`F_*` constants). Phase 1 (bindings) + Phase 2
  (self-sandbox at startup, `capsicum_autosandbox.c`).
- `std.casper` — DNS/passwd/sysctl delegation across the capability-mode
  boundary, with the **mandatory two-phase ordering** (open channels *before*
  `capsicum.enter()`) baked in. That ordering is the part everyone gets
  wrong; getting it right is the tell that this branch is sound.
- `std.audit` — audit trail for the permission layer (aeo's natural sink for
  "enforcement requested but unavailable").
- Platform-dispatched `spawn_sandboxed_{linux,bsd,stub}.c` with a fail-loud
  stub; even handles GhostBSD's missing `libcasper.so` symlinks.

**What's stale / incomplete (the honest gaps):**

1. **Pinned to v0.166.0**; main is well past it. Drift is most likely
   *mechanical* — the `STD_SRC`/`OBJ_DIR` Makefile lists and CHANGELOG
   `[current]` — not semantic, since the new C files are self-`#if`-guarded
   and won't textually conflict. Needs a rebase + re-pin.
2. **`rights_limit()` takes a raw int fd**; std.file/std.net don't expose
   their fds yet, so today it only works with inherited/raw-extern
   descriptors. **For aeo this is fine** — aeo spawns children with inherited
   fds — but it's the seam where the branch is unfinished.
3. **Auto-wiring Capsicum into `spawn_sandboxed` is explicitly deferred.** So
   automatic Capsicum containment of aeo-spawned backends isn't there; aeo
   would call `capsicum.enter()` explicitly. Genuinely-future phase.

**Recommendation (and aeo's stake in it):** revive it — rebase onto current
main, re-pin the Makefile lists, ship `std.capsicum` + `std.casper` +
`std.audit` as-is, leave spawn_sandboxed auto-wiring as the future phase.
**aeo should be its first real consumer.** Per aether/LLM.md, downstream
adoption is how Aether features get finished; aeo consuming `std.capsicum`
gives this branch the pressure to land. Until it merges, aeo's Capsicum
grammar targets this branch explicitly (document the required `ae` version /
branch in aeo's build).

Related branches seen alongside it (context, not dependencies):
`origin/docs/capsicum-sandboxing`, `fix/sandbox-clone3-seccomp`,
`fix/sandbox-preload-vfork-toolchain`, `feat/contrib-templating-liquid-sandbox-gate`.

---

# Open decisions (alternatives recorded, not yet chosen)

## Decision 1 — the `aeo` front-door

Choosing `aeo compose.ae` (over `ae run compose.ae`) is what earns aeo three
things a bare library-under-`ae-run` cannot have: an **injected `cap`**
(authority comes from the host, not the script), **lifecycle supervision**
(catch Ctrl-C mid-bring-up, walk the partial tree in reverse, tear down), and
**subcommands** (`aeo down`, `aeo status`, `--dry-run`). So aeo owns its
entrypoint. *How* that entrypoint is implemented is open:

### Option 1A — bash trampoline, like aeb today  *(ships now)*
Copy aeb's proven ~635-line pattern: bash sets `AETHER`/`AEO_HOME`/`cap`
grants, supervises the Aether composition process (process group +
signal-forward + timeout + group-reap), traps SIGINT → run teardown in
reverse. Matches aeb exactly; migrate to native later.
- **+** Ships immediately; battle-tested shape; unblocked on upstream.
- **−** A bash layer aeo must carry; duplicates aeb's trampoline concept.

### Option 1B — native Aether supervision primitives  *(cleaner, blocked)*
Be the first consumer of the not-yet-built native process-supervision
primitives Aether already tracks for aeb (aeb/TODO.md § "Full Aether CLI
entrypoint" + aether/aeb-process-supervision-primitives.md). Front-door is
pure Aether: `supervise(cap) { run_composition(); on_signal { teardown() } }`.
- **+** No bash; one language; the "right" long-term shape.
- **−** Blocks aeo on upstream Aether work.

**Note for the aether side:** aeo wanting these primitives makes it the
**second downstream** (after aeb) asking for the same supervision shape —
exactly the "two downstreams want it, now factor" signal aether/LLM.md says
to watch for. Worth filing regardless of which option aeo ships on.

**Possible third cut (raise before deciding):** v0 needs *no* supervision —
bring-up and teardown are separate invocations (`aeo compose.ae` up, `aeo
down compose.ae` down), no in-process Ctrl-C handling at all. Simplest;
defers 1A/1B entirely. Reverse-order teardown still needed, just driven by a
separate run rather than a signal trap.

## Decision 2 — resource handle model

How is `vm(a)` represented?

### Option 2A — actor per resource
`vm(a)` is an Aether `actor` with `state: Down|Booting|Up` and a `receive`
block (`Start`/`Probe`/`Stop`). `wait_for_it_to_be_up()` is a
receive-with-timeout polling `Probe` until `Up`. Maps "a VM is a long-lived
stateful thing you message" onto Aether's actor model natively.
- **+** Concurrency falls out for free (many resources booting at once);
  state machine is explicit; idiomatic Aether.
- **−** Pulls the actor runtime into v0; more machinery before first light-up;
  reserved-word footguns (`state`, `message`, `receive` — see aether/LLM.md).

### Option 2B — plain handle + imperative methods  *(simpler start)*
`vm(a)` is a struct; `.up()` / `.wait_for_it_to_be_up(timeout)` / `.down()`
are plain functions over it. Sequencing is just call order in `compose.ae`.
- **+** Minimal runtime; fastest path to a working bring-up; add actors later
  if concurrency demands.
- **−** Concurrent bring-up is manual; no built-in state-machine discipline.

Reasonable path: **start 2B, migrate hot paths to 2A** when parallel
bring-up of independent siblings becomes the bottleneck. The handle's public
surface (`up`/`wait_for_it_to_be_up`/`down`) can stay stable across the
switch, since both can present the same method names.

---

# Invariants to not break (early, but worth stating)

- aeo never reimplements aeb's static DAG / topo-sort / caching. It shells to
  aeb for build-graph work.
- aeo's binary is emitted from the aeo repo, never from aeb's repo.
- No YAML/HCL/JSON config parser in aeo. Composition is `.ae` run by `aeo`.
  External formats only via shell-out to tools that already parse them.
- `kind`/`backend` stays a setter — aeo's core is substrate-agnostic; bhyve
  is the first backend, not the definition.
- Downstream-of-Aether link line is always `$(ae cflags)` — never hand-crafted
  `-I`/`-L`/`-laether` (aether/LLM.md).
