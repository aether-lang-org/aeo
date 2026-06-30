# aeo — primer & purpose guide

Two audiences, one file. **For an LLM (me or a cousin) picking up work on aeo:**
this is the orient-fast primer — what aeo is, how it's shaped, the invariants
that keep it coherent, the footguns. Re-read at the start of every session. **For
an observer wanting to *use* aeo for its purpose:** the "What aeo is for" and "A
composition, end to end" sections are your entry; the rest is the engine room.

Not a CLAUDE.md. Short, opinionated, current as of ae 0.328 (2026-06-27).

---

## What aeo is for

aeo is an **infrastructure orchestrator**: from a single Aether composition it
stands up, keeps coherent, and tears down a deliberate *tree* of compute nodes —
FreeBSD jails + bhyve VMs, Linux podman/docker containers + LXC system containers
+ KVM VMs. Dependency-ordered bring-up gated on **health**, reverse-order teardown
that **verifies** each node is gone.

Its *purpose* — the thing it's actually for, not just what it does — is
**orchestrated trees of compute nodes that contain malware and are impregnable to
attack.** Every node can be **confined** (resource caps so it can't starve the
host; cap-drop/seccomp so it can't escalate; a deny-default network so it can't
phone home), **attested** (its image digest verified before boot, fail-closed),
and **audited** (every security decision written to a tamper-evident hash chain).
The confinement grammar is *substrate-portable*: one `limit{}` + `constrain{}`
vocabulary renders to FreeBSD rctl/Capsicum/pf **and** Linux cgroups/seccomp/
network. This is "infrastructure as a containment hierarchy," tracing to
[The Principles of Containment](https://paulhammant.com/2016/12/14/principles-of-containment/).

aeo is the third sibling to `aether` (the language) and `aeb` (the build runner),
born spun-out. **config IS code** — the composition is a `.ae` you *run*, full
Aether around the declarations; no YAML, ever.

## Status (honest, ae 0.328)

Working, with a **live-proven containment story**. Of six containment axes, **five
are live-proven on real hardware** (a rootless Fedora-atomic "Bazzite" box for
Linux, a GhostBSD box for FreeBSD):

| Axis | State |
|---|---|
| Linux container confinement (cgroups / cap-drop / netpolicy) | ✅ live — fork-bomb refused by `--pids-limit`; `deny_egress` node has no network |
| Image attestation (verify-before-boot, fail-closed) | ✅ live — a mismatched digest is refused at boot |
| Audit trail (tamper-evident hash chain) | ✅ live — an edited log is caught by `aeo audit` |
| FreeBSD jail boundary | ✅ live on GhostBSD |
| rctl resource caps | ✅ live on GhostBSD |
| pf inter-VM network delivery | ❌ the one red axis — a known if_bridge bug (the Linux per-flow netpolicy sidesteps it) |

Drivers all exist and the Linux ones (`containers`/`lxc`/`kvm`) are live-proven
end-to-end via `aeo up` on Bazzite. The front-door, the actor runtime, the compose
DSL, host-gating, lifecycle ops (snapshot/rollback/backup/prune/exec/restart), and
the audit trail are all built. See `TODO.md` for the per-item proven-vs-modeled
scorecard, `aeo-design.md` for the design, `README.md` for the user-facing tour.

## The one thing to never get wrong: aeo is NOT aeb

The load-bearing distinction. Burn it in:

- **aeb is declare-then-schedule.** Its DAG is static text, grep-extracted before
  any `.ae` runs; `build.dep()` is a runtime no-op; nodes are isolated subprocesses
  coordinating via on-disk markers.
- **aeo is imperative-runtime.** A resource handle is a *live reference in one
  running process*; a node comes up and aeo **blocks on its health** before the
  next; ordering is by health, not by artifact existence; teardown is a reverse
  walk that verifies disappearance.

**If you ever want to give aeo a static DAG / topo-sort / build cache — STOP. That
is aeb's job; aeo shells out to aeb for it.** The moment aeo reimplements a static
DAG it has become a second aeb and the factoring rots. aeo's value is *only* the
runtime layer.

| | aeb | aeo |
|---|---|---|
| grain | static DAG of artifacts | imperative orchestration of live nodes |
| dep | data (runtime no-op) | runtime reference (live) |
| time | build-time | run-time lifecycle (up / healthy / confined / down) |
| invoke | `aeb target:name` | `aeo up compose.ae` |
| one-liner | "build the tree" | "stand the tree up, keep it coherent, contain it" |

## A composition, end to end

A composition is an ordinary Aether module exporting `aeo_orchestration()` (no
args — the front-door calls it). The kind is the verb; the block configures it.

```aether
import compose (system, container)
import compose (image, health, depends, within, every, limit, limit_maxproc, constrain, deny_egress, attest)
exports ( aeo_orchestration )

aeo_orchestration() {
    system("web") {
        within(30s) every(500ms)          // health-retry window for the tree
        without(10s)                       // teardown: wait this long for "gone"

        db = container("db") {
            image("docker.io/library/redis:alpine")
            attest("sha256:cd5f3ac…")      // refuse to boot a mismatched image
            health("redis-cli ping")
            limit("db") { limit_maxproc(32) }      // cgroup fork-bomb ceiling
            constrain("db") { deny_egress() }       // -> --network none, can't phone home
        }
        app = container("app") {
            image("docker.io/library/myapp:latest")
            health("curl -fsS localhost:8080/healthz")
            depends(db)                    // db up + healthy before app starts
        }
    }
}
```

`aeo up` brings `db` up, blocks on its health, then `app`; `aeo down` stops `app`
before `db` and verifies each is gone. Two import lines (openers + setters) is the
ecosystem idiom. **Kind verbs:** `container`/`docker`/`lxc`/`kvm_vm` (Linux),
`jail`/`bhyve_vm`/`freebsd_vm` (FreeBSD). Setters are **single-arg** (Aether is
fixed-arity — repeat the call for more). `depends` takes a handle (typo-checked)
or a name string.

The seven `examples/silly_addition_*.ae` are the canonical surface — the same
`db ◄ app` app across every substrate (the "substrate grid"). Read one, diff
another. They're **all-in-one**: each declares the system AND self-verifies via
`AEO_MODE` modes (`check`/`up`/`smoke`/`suite`). The mode scaffold is repeated per
file ON PURPOSE — they're self-contained; do not factor it out.

## How it's built — the shape that matters

```
bin/aeo.ae         front-door CLI: stages a build dir, `ae build`s the composition,
                   runs it under os.run_supervised. Subcommands: up|down|status|
                   dry-run|snapshot|rollback|exec|restart|backup|prune|audit.
lib/aeo/runner.ae  the fixed runner: the resource ACTOR + bring-up/teardown engine.
lib/compose/       the operator DSL (config IS code). All grammar + getters.
lib/driver_linux/  podman/docker: build/run/probe + the confinement flags.
lib/driver_lxc/    real LXC (lxc-create/start/attach) — system containers.
lib/driver_vm/     KVM/qemu (Linux) + bhyve (FreeBSD).
lib/driver_bsd/    FreeBSD jail (jail/jexec/jls over a ZFS dataset).
lib/confine_linux/ limit{}/constrain{} -> cgroup/seccomp/network flags (the Linux peer).
lib/rctl/ lib/pf/  FreeBSD confinement: rctl caps + pf network policy.
lib/attest/        image attestation (verify-before-boot, 3 greppable states).
lib/audit/         tamper-evident hash-chained audit trail.
lib/snapshot/ lib/snapshot_linux/   lifecycle ops (ZFS ; podman/qemu-img/lxc).
lib/host/          host-profile probe + capsicum/casper gating.
lib/ipam/ lib/images/   IP allocation + golden-image recipe/realizer.
lib/resource/      the actor↔main STATE BRIDGE.
```

### The front-door codegen (a real Aether constraint, load-bearing)

**Aether actors are single-compilation-unit only.** `actor`/`message` defs and
their `spawn`/`!` sites must live in the file with `main`; they do NOT cross
`import`. So the resource actor can't be a plain importable lib. The front-door
(`bin/aeo.ae`) therefore **stages a build dir**: it copies `lib/` in, installs the
operator's compose file as the `aeo_compose` module, copies `lib/aeo/runner.ae`
(which contains the inlined actor + `main`) as the top-level entry, and `ae build`s
that single unit. `examples/` files are the hand-written shape of what gets staged.
On an immutable host where `ae` isn't on PATH, an `ae` container-shim builds it
inside a toolchain container (`docs/build-in-container.md`).

### State, never in a module `var`

ALL ambient / cross-module state goes through **`std.config`** (the C-extern
process-global KV) — never an Aether module-level `var`. `cursystem`/`curhost`,
the within/without float snapshots, node state, audit inputs: all `config.*`. This
is load-bearing: Aether's module `var` had a string of cross-import soundness bugs
(#929/#937) that aeo dodged *only* because it routes ambient state through config.
**Rule: ambient/cross-module/"current context" state = config, never a `var`.**

## Footguns (Aether constraints that will bite)

- **Reserved words** trip the parser: `state`, `match`, `message`, `receive`,
  `after`, **`spawn`** (the actor keyword — `spawn = "…"` parses as `spawn(` and
  errors "Expected LEFT_PAREN, got ASSIGN"; this bit driver_bwrap, a *non-actor*
  file, where a local was named `spawn`). Rename locals (`st`, `msg`, `spwn`).
- **`list_get` returns a ptr; `"${a}"` on it yields the ADDRESS, not the string.**
  To shell argv, pass the list DIRECTLY to `run_capture(prog, list)` (like
  driver_vm/driver_lxc), or `list_get_raw` + `list_add_raw` to copy element ptrs.
  Interpolating a list element into a command string silently mangles it. (This
  bit driver_lxc; driver_bsd's `_sudo_run` has the same latent bug — TODO.)
- **Nested string literals inside `${}` don't parse** — `"${f("x")}"` is a syntax
  error. Assign to a var first: `r = f("x"); "${r}"`.
- **Heredocs `<<TAG` are RAW** — no `${}` interpolation inside.
- **`getenv` for an unset var returns an empty string that `== ""` reports as
  FALSE** — `string_length(v) == 0` is true, yet `v == ""` is *false* (so a
  `== ""` default-guard silently never fires). Always guard with
  `string_length(v) == 0`, never `== ""`. (This bit `bin/aeo.ae`: the AEO_WORK
  default never applied → `aeo up` died with `cp: cannot create directory ''`.)
- **Multi-return is one-call destructure only** — `a, b = f()`. Don't chain.
- **Duration literals** (`30s`, `500ms`) are i64 ns; `/ 1000000` → ms (`as int` is
  rejected, `/` works). Used by within/every/without.
- **Selective `import std.string (...)` does NOT provide bare `copy()`** — the
  aeocha specs need a bare `import std.string` too (aeocha calls `copy`
  unqualified). #870/#878 fixed the *qualified* surface, not this.

## DSL conventions (don't fight them)

- **config IS code.** Composition is a `.ae` you run. NEVER add a YAML/JSON/HCL
  parser. External formats only via shell-out.
- **closure-with-setters**, single-arg, pure accumulation into the compose KV.
- **`os.run_capture(prog, argv, env)`** is the canonical spawn primitive every
  driver shells through (argv-based, no shell, binary-safe).
- **Drivers self-sudo where they need privilege**: `sudo -n <prog> …` so the aeo
  binary needn't be root (the operator pre-grants specific binaries NOPASSWD).

> **Academic precedent (cite, don't depend on):** Weiher/Taeumel/Hirschfeld,
> *Beyond Procedure Calls as Component Glue* (Onward! '24,
> doi:10.1145/3689492.3690052) is the canonical academic backing for
> config-IS-code-for-infra. Listings 41/42 are directory-sync-as-program where the
> *only* difference between the local and remote case is an `SSHConnection` store
> handle — aeo's substrate-portability pitch (one composition, local/remote differ
> by a handle), two years early. §8.7 (Plan 9 / "packaging mismatch") is the sharp
> argument for routing through a `.ae` rather than YAML-over-a-CLI: an OS-mediated
> abstraction "requires serialized representations, which have to be parsed,
> generated and accessed via the POSIX APIs … a form of packaging mismatch."
> **Where aeo diverges — the part that's genuinely ours:** Objective-S gets this
> via a polymorphic connection operator `→` backed by a metaobject protocol, and
> its remote story (L42) is `SSHConnection`-**reaches-into** the contained — the
> orchestrator dials *through* the boundary to a store inside. **aeo reverses the
> directionality on containment grounds.** L42's reach-in is the LiveConnect /
> DOM-monkey-patching antipattern Principles-of-Containment forbids (a container
> reaching into its contained's innards). So `lib/protocol/` + `aeo-agent`
> (`bin/aeo-agent.ae`) keep the paper's best idea — *a stable verb set with a
> replaceable transport beneath it* (`boot/halt/probe/announce/report` over
> `transport_file` now, `transport_http` later): a metaobject protocol in
> miniature — but invert the flow: **the contained reaches OUT and the parent
> listens; the parent messages a resident agent, never through the boundary.** The
> agent IS the standing live connection the paper describes via `→`, made concrete
> *and* containment-safe: the runner is just the depth-0 agent, the same actor
> protocol one boundary down. The front door still has **no `→` operator** and
> shells to aeb for static structure. So: same protocol-with-pluggable-transport
> factoring, opposite directionality — and the reversal is the novelty over the
> paper, not a retreat from it. (See `docs/aeo-agent.md`.)

> Historical note: early design docs (and old versions of this file) describe a
> `cap` threaded through every handle — `jail(cap, "db")`, `aeo(cap)` DI. That
> was the intended capability-injection shape; it is **not built** — today's
> openers are `kind(name){…}` and `aeo_orchestration()` takes no cap. Treat the
> `cap`/`require_capsicum()`/`prefer_capsicum()` grammar in older docs as
> aspirational, not current.

## The seam to aeb

Boring on purpose: **artifacts on disk + a CLI invocation.** aeb produces an
image/disk in `target/<module>/`; aeo boots a node around it. Mid-composition, aeo
can `run_capture("aeb", ["app:image"], env)` to build something it then deploys.
Don't over-engineer this into an in-process binding.

## Repo topology & invariants

```
~/scm/aether   the language; produces `ae`, `aetherc`, libaether.a
~/scm/aeb      build runner; built from Aether
~/scm/aeo      THIS repo; its own binary; built BY aeb (or `ae build`); calls aeb at runtime
~/scm/aeocha   the test framework aeo's specs use (aeocha.assert_*)
```

- aeo's binary is emitted from THIS repo, never aeb's (keeps infra backends out of
  aeb's core). Edges: build-time + run-time aeo→aeb. **No cycle.**
- Link line is always `$(ae cflags)` — never hand-crafted `-I`/`-L`/`-laether`.
- aeo is substrate-agnostic at the core — never hardcode one backend as "the" one.

## What NOT to do

- Don't give aeo a static DAG / topo-sort / build cache → that's aeb. Shell out.
- Don't add a config-file parser → composition is `.ae`.
- Don't put aeo's binary/build in the aeb repo.
- Don't hold ambient state in a module `var` → use `std.config`.
- Don't interpolate a `list_get` ptr into a command string → pass the list to
  `run_capture`, or use `list_*_raw`.
- Don't hand-craft Aether link flags → `$(ae cflags)`.
- Don't reinvent host detection → consume `std.capsicum.available()` etc.
- Don't factor the per-demo mode scaffold into a shared module → demos are
  deliberately self-contained.
- Don't overclaim "live" → keep the proven-vs-modeled discipline; say which box,
  which date, what was actually run.

## Git

`main` with two remotes: `origin` (SSH, git@github.com:aether-lang-org/aeo.git)
and `origin2` (HTTPS, same repo). **When port 22 is blocked** (some networks),
push via `origin2` — `gh auth setup-git` wires the credential helper. End commit
messages with:
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
