# Notes to self (LLM assisting on aeo)

Not a CLAUDE.md — short, opinionated, written for a future LLM picking up
mid-task. Re-read at start of every session.

**Status: design phase. No implementation exists yet.** The whole repo is
`aeo-design.md` + `README.md` + this file. Your first real coding task will
be scaffolding, not editing existing aeo code. Read `aeo-design.md` in full
before doing anything — it is the source of truth and it records the open
decisions you must NOT silently resolve.

## What aeo is, in one paragraph

aeo is an **infrastructure orchestrator**: it stands up and tears down a
deliberate *tree* of VMs and containers — FreeBSD jails + bhyve, Linux
LXC/Docker + KVM — from a single Aether composition script run as
`aeo compose.ae`. It is a third sibling to `aether` (the language) and `aeb`
(the build runner), born already-spun-out. aeo is *built by* aeb and shells
*to* aeb at runtime across a plain artifact + CLI seam. DSL philosophy is
inherited wholesale: **config IS code**, closure-with-setters, no YAML —
applied to live infrastructure instead of builds.

## The one thing to never get wrong: aeo is NOT aeb

This is the load-bearing distinction; the design doc spends its first section
on it. Burn it in:

- **aeb is declare-then-schedule.** Its DAG is static text, grep-extracted
  *before any `.ae` runs*; `build.dep()` is a runtime no-op; nodes are
  isolated `_static` subprocesses coordinating via on-disk `.rc` markers.
- **aeo is imperative-runtime.** `vm(a)` is a *live handle in one running
  process's memory*; `vm(a).wait_for_it_to_be_up()` blocks on liveness;
  ordering is by *health*, not by artifact existence; teardown is a reverse
  walk. This is the runtime-lifecycle layer aeb deliberately refuses to have.

**If you ever find yourself wanting to give aeo a static DAG / topo-sort /
build cache — STOP. That work is aeb's; aeo shells out to aeb for it.** The
moment aeo reimplements a static DAG it has become a second aeb and the whole
factoring rots. aeo's value is *only* the runtime layer.

Division of labor (full table in design doc):

| | aeb | aeo |
|---|---|---|
| grain | static DAG of artifacts | imperative orchestration of live resources |
| dep | data (runtime no-op) | runtime reference (`vm(a)` is live) |
| time | build-time | run-time lifecycle (up/healthy/down) |
| invoke | `aeb target:name` | `aeo compose.ae` |
| one-liner | "build the tree" | "stand the tree up and keep it coherent" |

## OPEN DECISIONS — do not resolve these silently

The design doc records two decisions left deliberately open. The user wants
them to stay open until *they* choose. Do not pick one and start building as
if it's settled. If a task forces the issue, surface the trade-off and ask.

1. **Front-door** (design doc Decision 1): bash trampoline like aeb today
   (1A, ships now) vs native Aether supervision primitives (1B, cleaner but
   blocked on upstream) vs a third cut (no supervision in v0; `aeo up` /
   `aeo down` as separate invocations). The front-door is what earns aeo its
   injected `cap`, lifecycle supervision, and subcommands — so *that* aeo owns
   its entrypoint is settled; *how* is open.
2. **Resource-handle model** (design doc Decision 2): Aether actor per
   resource (2A — state machine + receive, concurrency falls out) vs plain
   struct + imperative methods (2B — simpler v0). Public surface
   (`up`/`wait_for_it_to_be_up`/`down`) can stay stable across a later switch.

## Repo topology & dependency direction (invariant)

```
~/scm/aether   the language; produces `ae`, `aetherc`, libaether.a
~/scm/aeb      build runner; its own binary; built from Aether
~/scm/aeo      THIS repo; its own binary; built BY aeb; calls aeb at runtime
```

- **aeo's binary is emitted from THIS repo, never from aeb's repo.** Putting
  it in aeb would drag infra backends (bhyve/jail/ssh/libvirt) into aeb's
  CI and violate aeb's "no domain-specific in core" rule. Precedent:
  `aether-ui` and `servirtium-vcr` both spun out of parent repos for exactly
  this reason.
- Edges: build-time aeo→aeb, run-time aeo→aeb. **No cycle** — aeb never
  references aeo.
- "Built by aeb" is convenience, not law — aeo can bootstrap with `ae build`
  directly and adopt aeb later.
- Downstream-of-Aether link line is ALWAYS `$(ae cflags)` — never hand-crafted
  `-I`/`-L`/`-laether`. (Same rule the whole ecosystem follows.)

## Host adaptation & Capsicum gating (a real design requirement)

aeo **adapts to BSD vs Linux** and **fast-fails grammar the host can't
honor**. Two layers:

- **(a) backend selection** aeo writes: `uname`-based `driver_bsd`
  (jail/bhyve) / `driver_linux` (lxc/kvm) / `driver_stub` (fail-loud).
  `kind(...)` is a setter; a kind the host can't run is a **fast, loud error
  at composition-eval time**, before any resource is touched — not a silent
  no-op, not a failure three nodes deep.
- **(b) capability probes** aeo *consumes* from Aether: `std.capsicum.available()`
  / `std.casper.available()` already return 0 off-FreeBSD and degrade cleanly.
  Don't reinvent Capsicum host-detection — inherit this contract.

**Guarantee vs preference is the operator's call, explicit in grammar:**
`require_capsicum()` → fast-fail if `available()==0`; `prefer_capsicum()` →
degrade + loud `std.audit`-logged warning. (Fast-fail-vs-degrade table in
design doc.)

### Upstream dependency: `feat/freebsd-sandbox-parity`

aeo's Capsicum story rests on the Aether branch `feat/freebsd-sandbox-parity`
(GitHub aether-lang-org/aether), **not yet merged**. Assessment in the design
doc; the short version:

- It's GOOD, not a stale draft — ~1826 insertions atop v0.166.0: real
  `std.capsicum` (bindings + Phase-2 self-sandbox), `std.casper` (DNS/passwd/
  sysctl delegation with the correct two-phase ordering — the tell it was done
  right), `std.audit`, and `spawn_sandboxed_{linux,bsd,stub}.c` dispatch with a
  fail-loud stub.
- Stale parts: pinned to v0.166.0 (mechanical merge drift — the new C files are
  `#if`-guarded so they won't textually conflict); `rights_limit()` only works
  with inherited fds today (fine for aeo, which spawns children with inherited
  fds); spawn_sandboxed auto-wiring deferred.
- **aeo should be its first real consumer** — that's the downstream pressure
  (per aether/LLM.md) that gets the branch merged. Until it merges, document
  the required `ae` branch/version in aeo's build.

If you touch this: you may need to rebase the branch onto current Aether main
and re-pin the Makefile `STD_SRC`/`OBJ_DIR` lists. Check `~/scm/aether` —
`origin/feat/freebsd-sandbox-parity` is fetchable there.

## DSL conventions inherited from the ecosystem (don't fight them)

These come from `aether/LLM.md` + `aeb/LLM.md`; aeo follows them so an aeb
user reads an aeo `compose.ae` instantly.

- **config IS code.** The composition is a `.ae` the operator *runs*, not a
  YAML aeo parses. NEVER add a YAML/HCL/JSON config parser to aeo. External
  formats only via shell-out to tools that already parse them. If someone asks
  for a config loader, the answer is the closure-DSL — same as Aether's
  `docs/config-is-code.md`.
- **closure-with-setters.** `jail(cap, "db") { dataset(...) ip(...) }`. Setters
  are single-arg (Aether is fixed-arity — `f("a","b")` won't compile; repeat
  the call). Pure data accumulation into the handle/builder map.
- **`cap` threads through every handle** — `jail(cap,...)`, `vm(cap,...)`. The
  script *receives* authority to spawn; it does not construct it. Mirrors aeb's
  `aeb(cap)` entrypoint.
- **`os.run_capture(prog, argv, env)`** is the canonical spawn+capture+exit
  primitive every backend driver shells through (argv-based, no shell,
  binary-safe). `os.run_pipe*` if a backend needs a child→parent back-channel.
- **Reserved-word footguns** (from aether/LLM.md): `state`, `match`, `message`,
  `receive`, `after` trip the parser. If you go with the actor handle model
  (2A), expect to dance around these — rename locals (`st`, `is_match`, `msg`).
- **Multi-return is one-call-side destructure only**; for >1 return value use a
  map or split-accessor pattern. Don't design handle methods that need to
  ergonomically chain multi-returns.

## The seam to aeb ("casually hand to aeb")

Boring and robust on purpose: **artifacts on disk + a CLI invocation.**

- aeb → aeo: an aeb node produces an image/disk/jar in `target/<module>/`;
  aeo picks it up and boots a resource around it.
- aeo → aeb: mid-composition, `os.run_capture("aeb", ["app:image"], env)` to
  build something aeo then deploys. aeb is just another binary aeo spawns.

Don't over-engineer this into an in-process binding. (Aether's `--emit=lib`
first-class-import mechanism *could* do it; the value-add over shell-out is
unproven. Flagged, not adopted.)

## Worked reference: three-tier app on one host

The design doc carries a full worked `three-tier.ae` — db ◄ app ◄ web as
jails on one FreeBSD host, dependency-ordered bring-up gated on health checks,
reverse-order teardown, plus variants (a bhyve VM leaf; `require_capsicum()`).
When sketching grammar or examples, start from that one so the surface stays
consistent. It also enumerates what aeo is NOT (not a build, not multi-host by
default, not YAML).

## When you start implementing (likely first tasks)

Nothing here is built yet. Probable order, but confirm with the user — and
respect the OPEN DECISIONS above before committing to a front-door or handle
model:

1. Repo skeleton: `lib/driver_{bsd,linux,stub}/module.ae`, a bootstrap build
   file (`.build.ae` if going via aeb, or a plain `ae build` first), the `aeo`
   front-door (form depends on Decision 1).
2. One backend driver end-to-end — `jail` (BSD) is the natural first; it's the
   simplest real resource and exercises provision/start/health/teardown.
3. The host-profile probe + `kind(...)` gating (fast-fail path) — small, and
   it's the thing the user explicitly asked for.
4. `wait_for_it_to_be_up()` over a `health_check` shelling `os.run_capture`
   in a poll-until-zero-exit-or-timeout loop.

## What NOT to do

- Don't give aeo a static DAG / topo-sort / build cache. That's aeb's. Shell
  out.
- Don't add a config-file parser. Composition is `.ae`.
- Don't put aeo's binary or build in the aeb repo.
- Don't silently resolve the two open decisions. Surface, ask.
- Don't hand-craft Aether link flags. `$(ae cflags)`.
- Don't reinvent Capsicum host-detection. Consume `std.capsicum.available()`.
- Don't hardcode bhyve as "the" backend. `kind`/`backend` is a setter; aeo's
  core is substrate-agnostic.

## Git

Repo is local-only on `main`, no remote yet (initial commit `76417fb`). End
commit messages with:
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
