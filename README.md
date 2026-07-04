# aeo

**Infrastructure orchestrator** — stand up and tear down a deliberate tree of
VMs and containers (FreeBSD jails + bhyve, Linux containers/LXC + KVM) from a
single Aether composition, with dependency-ordered bring-up gated on health,
reverse-order teardown that *verifies* disappearance, per-node **confinement**
(cgroups / cap-drop / network policy on Linux; rctl / jail boundary on FreeBSD),
**image attestation** (verify-before-boot, fail-closed), and a **tamper-evident
audit trail**:

```
aeo up       compose.ae      # bring the tree up, dependency-ordered, gated on health
aeo status   compose.ae      # per-node state + confinement/attestation posture (--json too)
aeo down     compose.ae      # tear down in reverse order, verifying each node is gone
aeo dry-run  compose.ae      # validate + print the plan, touch nothing
aeo check    compose.ae      # run the composition's declared check() specs, NO deploy (CI/anywhere)
aeo smoke    compose.ae      # deploy + run smoke() specs, leave the tree STANDING
aeo suite    compose.ae      # deploy + run suite() specs, then TEAR DOWN (the CI shape)
aeo audit    compose.ae      # verify the hash-chained audit trail
aeo cutover  compose.ae node  # zero-downtime blue-green: green up + confined + health-gated, alias-swap, retire blue
aeo pasta    compose.ae on   # rootless source-IP fidelity: switch the port forwarder to pasta (see docs/linux-host-setup.md)
# also: snapshot | rollback | backup | prune | exec | restart  (per-node lifecycle ops)
```

The composition file is a **pure declaration** (no `main`, no self-test scaffold) —
`aeo` is the executor, exactly as `aeb <target>.build.ae` runs a build declaration.
A composition declares its OWN verification with first-class `check()`/`smoke()`/
`suite()` verbs that name external aeocha specs; `aeo <phase> compose.ae` runs them.

aeo is **not** a build system and **not** an aeb SDK. It is a third sibling to
[`aether`](https://github.com/aether-lang-org/aether) (the language) and
[`aeb`](https://github.com/aether-lang-org/aeb) (the build runner). aeo is
*built by* aeb and can shell *to* aeb at runtime, across a plain artifact + CLI
seam. Its DSL philosophy is inherited from the ecosystem — **config IS code**,
closure-with-setters, no YAML — applied to live infrastructure. Its containment
thinking traces back to [The Principles of
Containment](https://paulhammant.com/2016/12/14/principles-of-containment/) (see
[below](#principles-of-containment)).

> Status: **working v0, with a live-proven containment story.** Host probe,
> drivers for Linux (podman/docker, LXC, KVM) and FreeBSD (jail, bhyve), an
> actor-based runtime, the compose DSL, host-gating fast-fail, and the `aeo`
> front-door are implemented and verified end-to-end on real infrastructure. Of
> the six containment axes, **five are live-proven** — Linux container
> confinement (a fork-bomb refused by `--pids-limit`, a `deny_egress` node with
> no network), image attestation (a mismatched digest refused at boot), a
> tamper-evident audit trail (an edited log caught), the FreeBSD jail boundary,
> and rctl resource caps. The one red axis is FreeBSD pf inter-VM delivery (a
> known if_bridge bug; the Linux per-flow netpolicy sidesteps it). See
> [`aeo-design.md`](./aeo-design.md) for the full design, [`TODO.md`](./TODO.md)
> for the honest what's-proven-vs-modeled scorecard, and [`LLM.md`](./LLM.md) for
> the Aether constraints navigated.

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
calling the compose DSL. It exposes `aeo_orchestration()`, which the front-door
runs before bring-up. **config IS code**: the file is real Aether — control
flow, env lookups, conditionals — around the declarations.

```aether
import compose (system, container)
import compose (image, health, depends, within, every)

exports ( aeo_orchestration )

aeo_orchestration() {
    system("web") {
        health_retry() {                // health-timing knobs for the tree (see below)
            every(500ms)                // interval between probes
            up_within(30s)              // bring-up: retry health this long
            down_within(10s)            // teardown: wait this long for "gone"
        }

        // Tier 1: database
        db = container("db") {
            image("docker.io/library/postgres:16")
            health("pg_isready")
        }

        // Tier 2: app — depends on db, so db comes up (and is healthy) first
        app = container("app") {
            image("docker.io/library/myapp:latest")
            health("curl -fsS http://localhost:8080/healthz")
            depends(db)
        }
    }
}
```

The **kind is the verb** — `container(name) { ... }`, `jail(name) { ... }` — and
the opener returns a **handle** you can bind (`db = container("db") { ... }`) and
pass to `depends(db)`, so a typo'd dependency is a compile error rather than a
silent bad string. The bare-name setters inside configure that resource (its
name flows in as the block's context, so you don't repeat it). This is Aether's
trailing-block builder DSL: the call site reads like config, but the body is
full Aether (control flow, env lookups, conditionals). See
[`docs/closures-and-builder-dsl.md`](https://github.com/aether-lang-org/aether/blob/main/docs/closures-and-builder-dsl.md)
in the language repo for the mechanism.

Two import lines, the standard ecosystem idiom (cf. aeb's `import bash (script,
jobs, env)`): the openers (`container`, `jail`, …) and the block setters
(`image`, `health`, …).

`aeo up` brings `db` up and blocks until its health check passes before
starting `app`; `aeo down` stops `app` before the `db` it depends on. The
operator writes the tree once; direction is aeo's job.

Kind verbs: `container` / `lxc` / `kvm_vm` / `bwrap` / `nspawn` / `firecracker`
(Linux), `jail` / `bhyve_vm` / `freebsd_vm` (FreeBSD). `container` is the one OCI
app-container kind; which **engine** realizes it is the `engine()` property, not a
separate kind — `engine("podman"|"docker"|"wslc"|"wsl_podman")`, system-scope
float + per-node override, auto-resolving per host (Linux → podman → docker;
Windows → wslc / podman-in-WSL). So a Linux container and a Windows-hosted one are
the *same* declaration, differing by one engine string. `bwrap` is the lightest
tier — an unprivileged bubblewrap sandbox (no root, no host setup); `nspawn` is a
systemd-nspawn system container (the systemd-native LXC peer); `firecracker` is a
minimal-device-model microVM (the "smaller VM" peer of full KVM, live-proven boot
+ persist + teardown). Block setters (one arg per call — Aether is fixed-arity),
grouped by what they declare:

- **identity / lifecycle:** `image`, `command`, `entrypoint`, `dockerfile`,
  `health`, `depends`, `dataset`, `ip`, `env`, `expose`, `engine` (which OCI
  engine realizes a `container`; floats system-scope, auto per host)
- **health timing** (FluentSelenium-style duration literals), grouped in a
  `health_retry() { … }` block: `up_within(30s)` = retry-until-up window,
  `every(500ms)` = probe interval, `down_within(10s)` = retry-until-*gone* on
  teardown. (The loose form `within(30s) every(500ms) without(10s)` still works;
  `health_interval`/`health_budget` int forms remain.)
- **confinement** — `limit{}` caps (`limit_mem`, `limit_maxproc`, `limit_cpu`,
  `limit_openfiles`) and `constrain{}` (`grant_fd`, `egress`, `ingress`,
  `ingress_from`, `deny_egress`, `deny_ingress`). The *same* grammar renders to
  rctl/Capsicum/pf on FreeBSD and cgroups/seccomp/network on Linux —
  substrate-portable confinement.
- **supply chain:** `attest("sha256:…")` — pin a node's expected image digest;
  aeo verifies it before boot and refuses on mismatch.
- **device claims:** `gpu("shared"|"exclusive")` (+ optional `gpu_device(pin)`) —
  names the *contract* (container/lxc SHARE a GPU; a VM takes it EXCLUSIVELY via
  VFIO), and `aeo check` enforces the allocation (exclusive ∩ anything on one
  device fails; kind-mismatches fail). At `up` aeo probes `/etc/cdi` and prefers
  the structured CDI selector (`--device intel.com/gpu=all` — the full
  card+render+by-path bundle), falling back to the raw DRI device-map
  (`--device /dev/dri`) when no spec is present. Both proven live on a podman-6
  Intel N100. (See [`examples/cdi/`](./examples/cdi/) for a ready CDI spec.)
- **VM sizing:** `cpus`, `memory`, `nic`; **image recipes:** `from`, `install`,
  `systemd_unit`, `realize_as`, …

`depends` accepts either a handle (`depends(db)`) or a name string
(`depends("db")`) — handles are typo-checked, the string form is there for
references you don't have a binding for. (`resource(name, kind) { ... }` remains
as a general escape hatch.) See [`examples/`](./examples/) for twelve
compositions with the same `db ◄ app` shape across every substrate — the
substrate grid (read one, diff against another). Each example is a **pure
declaration** that names its own `check()`/`smoke()`/`suite()` verification specs;
`aeo <phase> <example>.ae` executes it.

## Running it

aeo compiles your composition into a supervised runner and executes it. Point
`AEO_HOME` at the aeo tree, then:

```
export AEO_HOME=/path/to/aeo
ae build $AEO_HOME/bin/aeo.ae -o ~/.local/bin/aeo --lib $AEO_HOME/lib
aeo up examples/silly_addition_containers.ae
```

The front-door (Decision 1B — native Aether, no bash trampoline) assembles a
build dir, `ae build`s the composition, and runs it under `os.run_supervised`
(own process group + signal forwarding + group reap). Resources are modeled as
Aether actors (Decision 2A) with a `down → booting → up` state machine and a
self-driven, `up_within`-bounded health-poll loop.

On an immutable host (e.g. a Fedora-atomic box) where `ae` isn't on the runtime
PATH, aeo builds the composition inside a toolchain container via an `ae`
container-shim — see [`docs/build-in-container.md`](./docs/build-in-container.md).
The Linux substrates (containers, KVM, LXC) are all live-proven this way.

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

## Principles of containment

aeo is, at heart, an exercise in
[The Principles of Containment](https://paulhammant.com/2016/12/14/principles-of-containment/):
the container sees and drives the contained; the contained only suspects it is
contained and cannot casually reach back unless the container configured it to;
and this should nest, restricting further at each boundary without the contained
knowing its depth. An honest scorecard of how aeo measures up today:

| Principle | aeo fit |
|---|---|
| Container sees the contained, drives it | **Strong** — aeo holds live handles and runs `up` / health-gated wait / `down` (teardown *verifies* the node is gone, not just flips a flag). |
| Contained can't casually reach the container | **Strong, control *and* data plane.** Control: a resource has no handle back to aeo. Data: `constrain{}` renders to a real deny-default — on Linux, `deny_egress` puts a node on `--network none` (no namespace — proven: it can't phone home); peer-only egress lands it on an `--internal` network (reaches its declared peer, not the internet); on FreeBSD the same grammar targets pf. |
| Reach out only where configured | **Strong** — the `image`/`command`/`env`/`expose`/`egress`/`ingress` setters _are_ the explicit, declared I/O surface; anything not declared is denied. |
| Don't starve the host | **Strong (live)** — `limit{}` renders to cgroup caps on Linux (`--memory`, `--pids-limit`: a fork-bomb is *refused*, proven) and rctl on FreeBSD (live on a jail). |
| Trust only what you pinned | **Strong (live)** — `attest("sha256:…")` verifies a node's image digest before boot, **fail-closed**: a mismatched/poisoned image is refused (proven), and the verdict is recorded in the audit trail. |
| Observe, tamper-evidently | **Strong (live)** — every confinement/attestation decision is written to a hash-chained audit log; `aeo audit` verifies the chain (an edited entry is caught, proven). |
| Authority injected, not constructed (DI) | **Strong** — the composition receives its authority to spawn from the front-door, it does not build it. Constructor injection (the [PicoContainer](https://picocontainer.com/) principle) applied to live infrastructure. |
| **Nestable; restrict at each boundary, depth-agnostic** | **Partial** — the grammar nests (`bhyve_vm("x") { container("app") { … } }`), `get_host` records the containment, the preflight gates a nested resource against its guest substrate, and the nest **executes** (a container inside a bhyve/KVM VM is built+run in the guest — see the `*_podman` demos). What's not yet built is *recursive depth-agnostic* nesting — see below. |

So aeo is a faithful realization of the post's **directionality and injection**
principles — arguably more so than some of the post's own exhibits, because
Aether's native capability model closes the "subvert IoC from within" hole the
post laments in the DOM. The **isolation** principles — don't-reach-out,
don't-starve, trust-what-you-pinned, observe — are now *enforced and live-proven*
on Linux (cgroups / cap-drop / `--internal` networks / digest attestation /
audit), from one substrate-portable grammar that also targets FreeBSD's
rctl/Capsicum/pf. Its **nesting** — the principle the post treats as defining —
executes one level (container-in-VM), but the *recursive, depth-agnostic* form is
still ahead. Closing that is **aeo-agent** (`docs/aeo-agent.md`): rather than aeo
reaching _through_ a boundary (ssh-ing in — the directionality the post calls a
disaster), the container hands its contained an agent, and that agent carries
orchestration deeper — receiving the instructions for its node and everything
below it, and in turn handing instructions to _its_ children's agents. Same
actor protocol at every level, so no node knows its depth — exactly the post's
"further restricted without knowledge of its nesting depth." That build takes aeo
from "the principles, live on one level" to "the post, recursively implemented."

## Layout

```
bin/aeo.ae            the front-door CLI (codegen + supervised run + subcommands)
lib/aeo/runner.ae     the fixed runner: the resource actor + bring-up/teardown engine
lib/compose/          the operator-facing compose DSL (config IS code)
lib/driver_linux/     podman/docker backend (build/run/probe + the confinement flags)
lib/driver_lxc/       real LXC system-container backend (lxc-create/start/attach)
lib/driver_bwrap/     unprivileged bubblewrap sandbox backend (rootless; pidfile-tracked)
lib/driver_nspawn/    systemd-nspawn system-container backend (machined-managed; self-sudo)
lib/driver_firecracker/  Firecracker microVM backend (config-file boot; pidfile-tracked)
lib/driver_vm/        KVM/qemu (Linux) + bhyve (FreeBSD) VM backend
lib/driver_bsd/       FreeBSD jail backend (jail/jexec/jls over a ZFS dataset)
lib/driver_stub/      fail-loud arm for unsupported host/kind
lib/confine_linux/    Linux confinement renderer: limit{}/constrain{} → cgroup/seccomp/net flags
lib/rctl/  lib/pf/     FreeBSD confinement: rctl resource caps + pf network policy
lib/attest/           image attestation (verify-before-boot, fail-closed; 3 greppable states)
lib/audit/            tamper-evident hash-chained audit trail (`aeo audit`)
lib/snapshot/  lib/snapshot_linux/   lifecycle ops: ZFS (jail/bhyve) + podman/qemu-img/lxc
lib/host/             host-profile probe + capsicum/casper gating
lib/ipam/  lib/images/  IP allocation + the golden-image recipe/realizer
lib/resource/         the actor↔main state bridge
lib/driver_windows/  lib/driver_wslc/   Windows OCI engines (podman-in-WSL2 / MSFT's native wslc.exe)
examples/             the substrate grid — twelve `db ◄ app` compositions (see examples/README.md)
examples/checks/      the per-example check()/smoke()/suite() aeocha specs
test/                 ~30 specs (fluent-aeocha style): driver/confinement/attest/audit/lifecycle/gpu/pasta + real-jail
```

## What aeo is NOT

Not a build (it `pkg install`s / pulls images, it doesn't compile — shell out to
aeb for that). Not multi-host by default (every node is local unless a future
`host(...)` control-plane form is used). Not YAML — the composition *is* the
config, full Aether underneath. Don't add a config-file parser; expose setters.
