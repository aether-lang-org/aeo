# aeo

**Infrastructure orchestrator** — stand up and tear down a deliberate tree of
VMs and containers (FreeBSD jails + bhyve, Linux LXC/Docker + KVM) from a
single Aether composition, with dependency-ordered bring-up gated on health
and reverse-order teardown:

```
aeo up   compose.ae      # bring the tree up, in dependency order, gated on health
aeo status compose.ae    # show each resource's live state
aeo down compose.ae      # tear down in reverse dependency order
aeo dry-run compose.ae   # validate + print the plan, touch nothing
```

aeo is **not** a build system and **not** an aeb SDK. It is a third sibling to
[`aether`](https://github.com/aether-lang-org/aether) (the language) and
[`aeb`](https://github.com/aether-lang-org/aeb) (the build runner). aeo is
*built by* aeb and can shell *to* aeb at runtime, across a plain artifact + CLI
seam. Its DSL philosophy is inherited from the ecosystem — **config IS code**,
closure-with-setters, no YAML — applied to live infrastructure.

> Status: **working v0.** Host probe, Linux (podman/docker) and FreeBSD (jail)
> drivers, an actor-based runtime, the compose DSL, host-gating fast-fail, and
> the `aeo` front-door are all implemented and verified end-to-end on real
> infrastructure (podman containers and a real FreeBSD jail). See
> [`aeo-design.md`](./aeo-design.md) for the full design and
> [`LLM.md`](./LLM.md) for the current state and the Aether constraints
> navigated.

## The one-line distinction

| | does | invocation |
|---|---|---|
| **aeb** | build the tree (static DAG of artifacts) | `aeb target:name` |
| **aeo** | stand the tree up and keep it coherent (live lifecycle) | `aeo up compose.ae` |

aeb is *declare-then-schedule* — its DAG is static text, `build.dep()` is a
runtime no-op. aeo is *imperative-runtime* — `vm(a).wait_for_it_to_be_up()` is
a live handle that blocks on liveness; ordering is by **health**, not by
artifact existence. aeo is the runtime-lifecycle layer aeb deliberately refuses
to have. If aeo ever needs build-graph work, it shells out to aeb.

## A composition

A composition is an ordinary Aether module that declares a resource tree by
calling the compose DSL. It exposes `aeo_declare(cap)`, which the front-door
runs before bring-up. **config IS code**: the file is real Aether — control
flow, env lookups, conditionals — around the declarations.

```aether
import compose (container)
import compose (image, health, depends)

exports ( aeo_declare )

aeo_declare(cap: ptr) {
    // Tier 1: database
    container("db") {
        image("docker.io/library/postgres:16")
        health("pg_isready")
    }

    // Tier 2: app — depends on db, so db comes up (and is healthy) first
    container("app") {
        image("docker.io/library/myapp:latest")
        health("curl -fsS http://localhost:8080/healthz")
        depends("db")
    }
}
```

The **kind is the verb** — `container(name) { ... }`, `jail(name) { ... }` — and
the bare-name setters inside configure that resource (its name flows in as the
block's context, so you don't repeat it). This is Aether's trailing-block
builder DSL: the call site reads like config, but the body is full Aether
(control flow, env lookups, conditionals). See
[`docs/closures-and-builder-dsl.md`](https://github.com/aether-lang-org/aether/blob/main/docs/closures-and-builder-dsl.md)
in the language repo for the mechanism.

Two import lines, the standard ecosystem idiom (cf. aeb's `import bash (script,
jobs, env)`): the openers (`container`, `jail`, …) and the block setters
(`image`, `health`, …).

`aeo up` brings `db` up and blocks until its health check passes before
starting `app`; `aeo down` stops `app` before the `db` it depends on. The
operator writes the tree once; direction is aeo's job.

Kind verbs: `container` / `docker` / `lxc` / `kvm` (Linux), `jail` / `bhyve`
(FreeBSD). Block setters (one arg per call — Aether is fixed-arity): `image`,
`command`, `health`, `dataset`, `ip`, `depends`, `health_interval`,
`health_budget`. (`resource(name, kind) { ... }` remains as a general escape
hatch.) See `examples/` for a Linux-container and a FreeBSD-jail composition
with the same `db ◄ app` shape — substrate independence at the DSL layer.

## Running it

aeo compiles your composition into a supervised runner and executes it. Point
`AEO_HOME` at the aeo tree, then:

```
export AEO_HOME=/path/to/aeo
ae build $AEO_HOME/bin/aeo.ae -o ~/.local/bin/aeo --lib $AEO_HOME/lib
aeo up examples/aeo_compose/module.ae
```

The front-door (Decision 1B — native Aether, no bash trampoline) assembles a
build dir, `ae build`s the composition, and runs it under `os.run_supervised`
(own process group + signal forwarding + group reap). Resources are modeled as
Aether actors (Decision 2A) with a `down → booting → up` state machine and a
self-driven health-poll loop.

## Host adaptation & fast-fail

aeo adapts to whether the host is BSD or Linux and **fast-fails before touching
any resource** when a composition can't run here:

- A `kind` the host can't execute (a `jail` on Linux, a `container` on BSD) is
  a loud error at composition-evaluation time, not a silent no-op three nodes
  deep.
- A `depends()` on an undeclared resource (or itself) is caught the same way.
- Capsicum/Casper enforcement consumes Aether's `std.capsicum` /
  `std.casper` `available()` contract (merged from `feat/freebsd-sandbox-parity`)
  rather than reinventing host detection — the host probe reports
  `family=bsd, capsicum=yes` on FreeBSD and `family=linux, capsicum=no` on
  Linux.

`aeo dry-run` runs all of this validation and prints the resolved bring-up plan
without starting anything — the operator's pre-flight.

## Layout

```
bin/aeo.ae            the front-door CLI (codegen + supervised run + subcommands)
lib/aeo/runner.ae     the fixed runner: the resource actor + bring-up/teardown engine
lib/compose/          the operator-facing compose DSL (config IS code)
lib/driver_linux/     podman/docker backend (idempotent up/down + liveness probe)
lib/driver_bsd/       FreeBSD jail backend (jail/jexec/jls over a ZFS dataset)
lib/driver_stub/      fail-loud third arm for unsupported host/kind
lib/host/             host-profile probe + capsicum/casper gating
lib/resource/         the actor↔main state bridge
examples/             Linux-container and FreeBSD-jail compositions
test/                 driver + host smokes; the real-jail bring-up test
```

## What aeo is NOT

Not a build (it `pkg install`s / pulls images, it doesn't compile — shell out to
aeb for that). Not multi-host by default (every node is local unless a future
`host(...)` control-plane form is used). Not YAML — the composition *is* the
config, full Aether underneath. Don't add a config-file parser; expose setters.
