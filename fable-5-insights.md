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
- `docker()`, `wslc()`, and `windows()` kind-verbs → **deleted outright** (Paul,
  2026-07-04: pre-1.0, no back-compat needed — no deprecated aliases). Container-
  on-Windows is just `container()` with host-family engine resolution. The
  `silly_addition_windows`/`_wslc` examples collapse into "the containers demo
  deployed on a Windows host" — the substrate grid gets SMALLER while covering
  the same ground.
- The full post-change taxonomy (what stays OUTSIDE `container()` — seven kinds,
  each failing the swap test for its own concrete reason): system containers
  `lxc()` + `nspawn()` (template/rootfs images, own init — and they don't merge
  with EACH OTHER either: dist:release template vs rootfs dir, template init vs
  --boot/payload); sandbox `bwrap()` (no image at all); `jail()` (dataset/ip/
  rctl); VMs `kvm_vm()`/`bhyve_vm()`/`freebsd_vm()`/`firecracker()` (whole
  machines — firecracker is the "smaller VM," but a VM, never a container
  candidate).
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

## F. OPEN: architect-vocabulary root nodes — `application()` / `service()` / `worker()`

Paul's prompt (2026-07-04): `system()` is the coined root today; architects might
want `application()` and `service()` (definite connotation: listens on a socket).
What's the term for "runs its own loops, NO external listening interface"?

**Answer: `worker`** — canonical since the Heroku/12-factor process model split
`web` (listens) from `worker` (own loop, pulls from a queue, no inbound). .NET's
template is literally "Worker Service"; Sidekiq/Celery use the same noun. The
neighbors and why not: **daemon** (Unix background, but daemons often listen),
**batch/job** (the mainframe word, but implies run-to-completion, not a standing
loop), **controller/reconciler** (the k8s control-loop — right shape, specifically
the state-convergence flavor), **consumer** (implies the broker), **agent**
(taken/loaded in aeo), **headless** (no UI ≠ no socket).

**The twist that makes it worth doing** — mere synonyms of `system()` would
violate our own rule (*name what's fixed by construction*). But these connotations
are CHECKABLE against the declared tree, and the grammar already has the
machinery:

- `service("api"){}` → asserts ≥1 node exposes/ingresses a port; a service
  listening on nothing FAILS `aeo check`.
- `worker("reaper"){}` → asserts NO node has expose()/ingress() — and can default
  `deny_ingress` across the tree (egress to queue/db still per-node). The
  architect's noun compiles to an enforceable interface posture; a worker that
  sprouts a listener is caught at check time.
- `system()` stays the neutral structural root.
- Possible second step: `application()` as the umbrella containing `service{}`/
  `worker{}` groupings (the openers already nest).

Sub-flavors if ever needed, split by what drives the loop: queue-driven
(worker/consumer), state-driven (controller/reconciler), clock-driven
(scheduled/cron) — all ingress-free.

STATUS: open exploration, not decided.

## G. PROPOSED: `gpu(mode)` — device claims with checked allocation semantics

From the XDA article's sharpest point (the Kalle comment): **VM passthrough is
EXCLUSIVE** (VFIO detaches the device from host + everyone else), **LXC/container
device-mapping is SHARED** (many consumers on one iGPU simultaneously). That's an
allocation-semantics axis that decides substrate choice — so aeo should declare
it and CHECK it, not leave it as homelab folklore.

**Grammar** (peer of cpus()/memory() as a claim; renders via the grant machinery;
audited like confinement):

    container("transcoder") { gpu("shared") }              // coexists with other shared
    kvm_vm("training") {
        gpu("exclusive")                                    // device LEAVES the host
        gpu_device("pci:0000:01:00.0")                      // optional pin; default any
    }

Modes: `"shared"` (shared ∩ shared OK), `"exclusive"` (∩ anything = conflict),
`"slice"` reserved (MIG / SR-IOV VF — exclusive-ish sub-devices, later).

**Per-substrate rendering** (all real mechanisms today): podman `--gpus`
(**podman 6.0, ~2026-06, made `--gpus` work with AMD GPUs too — so a single
`--gpus` renders `gpu("shared")` uniformly on podman, not just the DRI mount;
bazzite is AMD, testable here**) or `--device /dev/dri` / CDI nvidia on older
podman; docker `--gpus`; **wslc `--gpus` (already in its run flags — seen in the
CLI probe)**; lxc cgroup device-allow + /dev/dri mount (the Proxmox `dev0:`
pattern); kvm/bhyve exclusive via VFIO/ppt; jail devfs ruleset; bwrap
`--dev-bind`. REFUSED at check: any gpu() on firecracker (no device model);
`shared` on VM kinds until vGPU/SR-IOV support exists (honest frontier).

**The earn-its-place part — check-time allocation rules:**
1. exclusive ∩ anything on one device → FAIL `aeo check`, with the article's
   reasoning as the error text ("exclusive passthrough removes the device from
   the host; move shared consumers to the container/lxc tier or pin a second
   device"). The human tier-choice becomes a machine-checked constraint.
2. Capability gating per kind at check, not deploy-time surprise.
3. Host preflight probes the device exists (/dev/dri/renderD*, nvidia nodes).

Obeys the naming rule: `gpu("shared")` names the CONTRACT (coexistence
semantics); the mechanism (--device vs VFIO vs devfs) varies per substrate and
belongs to the drivers.

STATUS: proposed 2026-07-04, not built.

## H. PROPOSED: `nested_virt()` — deny-by-default, attenuate-down-the-tree

Paul's prompt (2026-07-04): turn nested virtualization OFF for child nodes even
when the parent ordinarily has it — principles of containment.

**Doctrine:** capability must ATTENUATE down the containment tree; it never flows
down implicitly. A node with nested virt can stand up its own hypervisor —
sub-VMs aeo can't see — breaking tree-is-truth, dodging structural limit{}
accounting, and riding the historically buggy nested-VMX path. It's the
compute-capability twin of deny_egress: a pure workload never needs it. And a
node that legitimately needs children should DECLARE them in the composition
(the aeo-agent delegate path), not get raw /dev/kvm to freelance — deny-default
forces sprawl INTO the tree, where it's orchestrated/confined/audited.

**Grammar:** `nested_virt()` — an explicit per-node grant. Semantics:
1. **Deny = ACTIVE masking, not passive absence** — even when the substrate
   default leaks it (host-passthrough CPU exposes vmx/svm): `-cpu host,-vmx,-svm`
   on child VMs; no /dev/kvm mapping + cgroup device-deny (c 10:232) for
   containers/lxc; `[wsl2] nestedVirtualization=false` for the WSL tier.
2. **No float-down** — unlike health_retry, the grant does NOT inherit; every
   level re-declares. Attenuation by default, amplification never.
3. **Check-time CHAIN validation** — can't grant what the ancestry lacks: host
   kernel nested=1 → VM has vmx → container maps /dev/kvm; a break anywhere
   fails `aeo check` with the chain spelled out. (Live scar tissue: the
   bazzite → Win11 → WSL2 → podman 3-deep chain needed each layer enabled by
   hand; the guest's "wsl: Nested virtualization is not supported" was a masked
   layer observed in the wild.)
4. **Refused where ungrantable** — nested_virt() on firecracker (no device
   model) or jail = check error, honest.
5. **Audited** — a virt grant is a security event in the hash chain, like
   attest/confine.

For containers the grant IS a device grant (/dev/kvm is a kernel object —
grant_fd vocabulary, same family as gpu()); the contract name stays
mechanism-free per the naming rule (the mechanism — CPU-flag mask vs device map
vs wslconfig — varies per substrate and belongs to the drivers).

STATUS: proposed 2026-07-04, not built.

## I. WIDE SWEEP (2026-07-04): journaling, witnessing, replication, failover,
## cutover-slider, router grammar — the connector-type harvest

Paul's prompt: go wide — journaling, witnessing, active replication, failover,
blue-green with a human percentage slider, "reverse-proxying" in the grammar
(term hated, rightly), following Daniel Flower's projects
(intercepting-forward-proxy, app-runner-router, cranker-connector, app-runner,
http-proxy-cache, app-migrator, javasysmon) + HSBC's mu-cranker-router.
Unifying observation: most of these are CONNECTOR TYPES — the Beyond Procedure
Calls thesis again (standing relationships deserve first-class grammar). Session
rule applied throughout: no verb without a check.

1. **journal(){ retain(30d) sink(...) }** — WAL semantics for orchestration:
   write-intent-BEFORE-acting, then the outcome. Payoffs: interrupted `aeo up`
   RESUMES from the journal; journal-vs-live drift is detectable; the existing
   hash-chained audit widens from security decisions to lifecycle events.
   Check: chain integrity (aeo audit); replay reconstructs status.

2. **witness("w1"){ observes("db") apart_from("db") }** — two flavors: quorum
   witness (tie-breaker voter, prevents 2-node split-brain) and ATTESTATION
   witness (observes peers' health/attest streams, keeps its OWN signed journal
   — two independent hash chains that must agree; divergence = tampering or
   partition; non-repudiation for the orchestrator itself). Check: witness
   co-located with its subject = error → requires FAILURE DOMAINS as supporting
   grammar: domain("rack1") / apart("a","b") — cheap, foundational.

3. **replication{ from("db-1") to("db-2") lag_within(5s) }** — the replication
   LINK as a first-class edge with its own health (replicas(3) alone can't
   order a failover — it never declared who replicates whom). Check: failover
   refuses to exist without a declared edge; lag probed.

4. **failover("db"){ primary(...) standby(...) witness(...) promote_within(30s)
   manual() }** — aeo's unfair advantage: **FENCING = CONFINEMENT**. The
   step everyone bolts on (STONITH agents), aeo already owns: fence the failed
   primary with deny_egress + halt — existing containment grammar applied
   posthumously. Check: quorum arithmetic (2 voters need a witness);
   primary/standby in different domains; replication lag was in bounds.

5. **cutover("app"){ blue(...) green(...) weight(0) slider() guard(spec) }** —
   the human-slider blue-green (strictly: a weighted canary with a human hand,
   the better thing). `aeo weight <file> app 25` moves it live. aeo-flavored:
   (a) the slider is an AUDITED runtime input (who/when, hash-chained);
   (b) slider position is journal state — survives restarts; (c) green is
   ineligible for weight>0 until its declared smoke() spec PASSES — the
   check/smoke/suite verbs become the promotion gate.

6. **router("edge"){ ingress(443) route("/", "app") route_weighted(...) }** —
   the traffic element, named honestly (app-runner-router / mu-cranker-router
   lineage; "reverse proxy" describes packet topology, not role). THE CHECK
   THAT EARNS IT: only router() nodes may hold public ingress — any other node
   with internet-facing ingress fails `aeo check`. North-south enters via
   declared edges or not at all: an architectural invariant, machine-enforced.
   From the Flower set also: **egress_via("guard")** (http-proxy-cache /
   intercepting-forward-proxy) — all outbound through a declared caching/
   attesting proxy node: auditable egress, deterministic fetches, supply-chain
   attestation AT the proxy (composes with attest()); **aeo migrate <node>
   <host>** (app-migrator) — composes replicate → cutover → retire;
   **javasysmon** → not grammar: `aeo status` grows actual-vs-limit{} gauges.

7. **CRANKER SEED (follow-up promised)** — the "reverse reverse proxy": the
   app-side connector DIALS OUT to the router and registers; requests flow back
   down the established connection; the app NEVER LISTENS (NAT-friendly, zero
   ingress). This is the resident-agent doctrine applied to the DATA PLANE, and
   it detonates §F's service/worker split in the best way: with a cranker-style
   connector, EVERY node can carry worker posture (deny_ingress everywhere) and
   still serve — only routers hold sockets.
       worker("app") { container("app"){...} serves_via("edge") }
   A tree that is deny-ingress except its declared edges = the strongest
   containment posture an orchestrator can ship by default.

Priority: domains/anti-affinity + journal are foundations (cheap, everything
leans on them) → router + cutover/slider (most visible, exercises the smoke
gate) → replication + failover + witness (deepest design risk, last) →
cranker/serves_via (the follow-up discussion).

STATUS: idea sweep, none built; cranker follow-up owed.

## J. CRANKER FOLLOW-UP (2026-07-04): two-part registration — the injected channel

Paul's framing: cranker lets a child register with a parent router to receive web
traffic as part of a cluster; principles of containment ordinarily forbid a child
finding/dialing a parent's port-listener — but a channel can be EXPLICITLY
INJECTED into the child by the grammar, making an effective TWO-PART registration.

**Confirmed from the repos (mu-cranker-router + cranker-connector READMEs):**
registration IS over WebSockets (wss://; connector config = router URL(s) via DNS
or fixed, withRoute("path-prefix"), local target URI); the router holds TWO
listeners (public HTTPS + a separate registration WSS server); HTTP semantics
maintained over the tunnel (framing detail not on-page; V1 idle-socket-pool /
V3 multiplex is from prior knowledge, unconfirmed); the live websocket IS the
liveness signal; graceful drain built in (stop(timeout) deregisters, waits
in-flight); and REGISTRATION AUTH IS BYO — the README asks operators to bolt on
firewall/mTLS/basic-token protection. That bolt-on is exactly what the
composition should supply first-class.

**The two-part registration** (the agent's addressing doctrine — "the contained
never told me where it lives; I assigned it" — applied to the data plane):

Part 1, declaration time (aeo acts; child passive):
  1. mint a per-child registration secret (agent_auth.mint_secret — exists);
  2. provision the EXPECTATION on the router: route ↔ HMAC binding ("accept a
     connector for /api bearing this; nothing else for /api");
  3. inject into the child at launch: AEO_SERVE_URL/ROUTE/TOKEN — assigned,
     never discovered;
  4. render the netpolicy: child egress-allow to EXACTLY edge:registration-port,
     deny-all else stands — the channel is a declared flow punched through
     confinement, not a hole in it.
Part 2, runtime: connector dials wss out, presents token+route; router verifies
against the provisioned expectation; mismatch → refused + audited. Route hijack
structurally impossible: you can only register what was granted.

**Grammar:**
    router("edge") { ingress(443) registrations(8008) }
    worker("app") {
        container("app") { image("…") }
        serves_via("edge", "/api")
    }
Checks: serves_via must target a router(); the node must have NO ingress() (the
point — error otherwise); same route on N nodes = the load-balanced set
(deliberate, cranker's cluster behavior); serves_via may name a router SET (HA —
"one or more routers" confirmed).

**Falls out for free:** a probe path that never touches the node (the router's
registration table as health source — connection-is-liveness, confirmed);
`aeo drain` = the confirmed stop(timeout) semantics (deregister → in-flight →
halt; down_within = drain timeout); the §I cutover slider's mechanism (v1+v2
register the same route, router weights between registration groups); and the
agent/connector answer — same dial-out shape + courier doctrine, DELIBERATELY
different secrets/endpoints (control vs data plane must not share compromise),
with the agent COURIERING the connector credential: the delegate message carries
the serves_via grant down. One courier ride, two channels.

**RESPONSIBILITY ASSIGNED (Paul, 2026-07-04): the aeo-agent sets up the active
cranking.** Not just couriering the credential — the resident agent IS the
connector host. Consequences this pins down:

1. **Sidecar, not library** — stock cranker's connector is a Java library the
   app embeds; agent-hosted cranking means the WORKLOAD IS UNMODIFIED (it just
   serves localhost). The agent, already resident and already trusted, opens
   and maintains the wss registration pool beside it.
2. **Control plane bootstraps data plane** — the delegate message over the
   authenticated agent channel carries the serves_via grant (route + router
   endpoint + minted token); the agent then stands up the data channel.
   Attenuation preserved: the agent can only crank what the composition
   declared.
3. **Attest gains a data-plane axis** — the agent's self-attest answers "am I
   registered at edge for /api and NOTHING else?" — drift between declared and
   actual routes is an attest failure, from inside the boundary.
4. **Ordered teardown built in** — halt verb → agent drains FIRST (deregister,
   wait in-flight per the confirmed stop(timeout) semantics) → then stops the
   workload. down_within = the drain window.
5. **Supervision** — re-registration on router restart, pool replenishment,
   and registration liveness folded into the agent's status reporting: the
   parent learns "up AND serving" through one channel.

STATUS: design discussion recorded; aeo-agent = connector host decided; not
built. Framing-protocol details (V1 pool / V3 multiplex) to confirm before
implementing.

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
