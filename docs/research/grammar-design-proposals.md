# aeo: Grammar Design Proposals and Research

Record of design exploration (2026-07-04 onwards) for advanced features: substrate-independent grammar, connector types, multi-node orchestration semantics, and deployment patterns. This captures the thinking that informs decisions, some built, some open for implementation.

## D. DECIDED & BUILT (2026-07-04): `container()` + `engine()` property

**Status:** BUILT + LIVE-PROVEN on Linux (podman, docker), Windows (wslc), tested on FreeBSD.

### The Problem

Multiple container runtimes exist on Linux (podman, docker) and Windows (wslc, native WSL podman). aeo should allow switching engines without rewriting the entire composition. But not all "engines" are truly interchangeable — LXC is semantically different (template images, own init, no port-publish concept).

### The Solution: Engine Float

- `container()` = the OCI app-container kind (the common interface)
- New `engine("podman"|"docker"|"wslc")` property — **system-scope float + node override** (same machinery as `within/every`)
- Auto default per host family: Linux → podman → docker; Windows → wslc → podman-through-WSL
- Setters that swap engine unchanged: `image()`, `health()`, `expose()`, `env()`, `limit{}`, `constrain{}`

### What Does NOT Go in `engine()`

LXC fails the swap test on nearly every row (image namespace, expose, env, payload model). Keeping it a separate `lxc()` kind is correct; other container-adjacent kinds (`nspawn`, `bwrap`) also stay separate.

### Full Taxonomy (Kinds that Stay Outside `container()`)

| Kind | Why It's Not an Engine |
|------|------------------------|
| `lxc()` | Template images (`dist:release`), own init, no port-publish |
| `nspawn()` | Rootfs dir, machinectl, systemd-native |
| `bwrap()` | No image at all; unprivileged sandbox |
| `jail()` | Dataset/IP/rctl-based, no OCI registry |
| `bhyve_vm()`, `kvm_vm()`, `firecracker()` | Whole machines, not containers |

### Naming Rule Extracted

**Name what's fixed by construction; parameterize what varies.**
- `container` stays generic because the engine varies
- `wslc`, `firecracker`, `kvm` name their realizer because the realizer IS the tier
- `wsl_podman` would repeat the mistake (a one-token driver change away from `podman_container`)

### Bug Fixed En Route

The `docker` kind's dispatch is second-class in older versions — it goes through plain `up()` and silently loses the shared `aeo-<system>` network, `env()` pairs, and ALL `limit{}`/`constrain{}` rendering. Routing docker-pinned nodes through the one confined path removes the fork by construction.

### Caveat: Network Plane Separation

Podman and docker networks are separate planes on the same host. Heterogeneous engines *within one system* can't resolve peers by name (published-port bridging only). The runner should warn if this is detected.

---

## E. OPEN: General Container Nesting (the Proxmox Docker-in-LXC Pattern)

**Status:** Open exploration; aeo-agent design will generalize this.

### Ground Truth from Homelab

Running an OCI engine inside an LXC is mainstream (Proxmox community-scripts, XDA forums, Jul 2025). Why:

- **Resource-starved hosts:** A decade-old laptop that can't run one VM runs a dozen LXCs. Docker-in-LXC gives container workloads without VM overhead.
- **Device sharing:** LXC shares host iGPU/PCIe across multiple consumers simultaneously; VM passthrough is exclusive.
- **The costs:** Weaker isolation than a VM; host upgrades can break nested-docker; unprivileged LXC needs `nesting=1` + privileged for CIFS/NFS mounts.

### aeo's Existing Seam

Every host-capable kind already exposes `exec_capture`:
- LXC → `lxc-attach`
- nspawn → `systemd-run --machine`
- jail → `jexec`
- VM → ssh
- container → `podman exec`

**Nested bring-up IS "send the child engine's commands through the host's exec seam"** — the VM path is just one instance. Generalizing:

1. Make `lxc()` (and `nspawn()`) block-host openers (set `curhost`, like VM openers) so:
   ```aether
   lxc("dockerbox") { container("web") { engine("docker") } }
   ```
   declares the Proxmox pattern directly.

2. Route nested bring-up by the HOST's kind: `get_kind(get_host(nm))` picks the exec transport for the same engine command stream. One generalized `nested_container_up` over `driver_exec` instead of VM-only special case.

3. The resident-agent path generalizes identically — aeo-agent can live in an LXC as well as a VM.

4. Per-host-kind prereqs recorded, not hidden: lxc needs `nesting=1` (+ privileged for NFS/CIFS volumes); guest userland needs the engine installed (same seed-installs-podman story as the VM path).

5. Nesting matrix = host-capable kinds × nestable kinds, each cell gated on "exec seam exists + child runtime can run there" — a compose-time validation, loud at `aeo check`, not a deploy-time surprise.

### Design Benefit

Unleashes resource-constrained deployments and device-sharing patterns without exposing the containerization complexity. Same grammar everywhere: just nest.

---

## F. OPEN: Architect Vocabulary — `application()` / `service()` / `worker()`

**Status:** Open exploration; decision pending.

### The Question

`system()` is the structural root today. Architects might want semantically-loaded roots: `application()` and `service()` (implies listens), and a term for "runs its own loop, NO external listening interface" (a `worker`).

### The Answer: `worker`

**Canonical since Heroku/12-factor:** split `web` (listens) from `worker` (own loop, pulls from queue, no inbound). .NET templates use "Worker Service"; Sidekiq/Celery use the same noun.

### Not Mere Synonyms

These connotations are **checkable** against the declared tree:

- `service("api"){}` → asserts ≥1 node has `expose()`/`ingress()`; a service listening on nothing FAILS `aeo check`
- `worker("reaper"){}` → asserts NO node has `expose()`/`ingress()` — can default `deny_ingress` across the tree (egress to queue/db still per-node). The architect's noun compiles to an enforceable interface posture; a worker that sprouts a listener is caught at check time.
- `system()` stays the neutral structural root
- Future: `application()` as the umbrella containing `service{}`/`worker{}` groupings

### Sub-Flavors (If Needed)

Split by what drives the loop:
- **Queue-driven:** `worker`, `consumer`
- **State-driven:** `controller`, `reconciler` (k8s control-loop)
- **Clock-driven:** `scheduled`, `cron`

All ingress-free; all are deployable roots.

### Design Benefit

Turns loose architectural intent into compile-time constraints. "This is a service" → machine-checked to listen.

---

## G. BUILT & LIVE-PROVEN (2026-07-04): `gpu(mode)` — Device Claims with Checked Allocation

**Status:** BUILT + LIVE-PROVEN on Intel Alder Lake-N iGPU, podman 6, CachyOS.

### The Problem

**VM passthrough is EXCLUSIVE** (VFIO detaches the device from host + everyone else). **LXC/container device-mapping is SHARED** (many consumers on one iGPU simultaneously). That's an allocation-semantics axis that should be declared and checked, not left as homelab folklore.

### Grammar

Peer of `cpus()`/`memory()` as a claim; renders via the grant machinery; audited like confinement:

```aether
container("transcoder") { gpu("shared") }              // coexists with other shared
kvm_vm("training") {
    gpu("exclusive")                                    // device LEAVES the host
    gpu_device("pci:0000:01:00.0")                      // optional pin; default any
}
```

Modes: `"shared"` (coexists), `"exclusive"` (conflicts with anything), `"slice"` (reserved for MIG / SR-IOV VF — exclusive-ish sub-devices, future).

### Per-Substrate Rendering

**CRITICAL CORRECTION** (live, 2026-07-04, Intel Alder Lake-N, podman 6):

Earlier claim that podman 6's `--gpus` renders uniformly is **WRONG for Intel**. `podman run --gpus all` FAILS on Intel — `--gpus` is a CDI front-end, CDI specs are generated by vendor toolchains (nvidia-ctk, amd), Intel iGPUs get none by default.

**The vendor-agnostic path:** DRI render-node device-map works on ALL:
```bash
--device /dev/dri/renderD128  # Intel, AMD, NV all support this
```

**aeo's rendering:**
- `gpu("shared")` → `--device /dev/dri/renderD128` (proven live: container sees host iGPU, bare container does not)
- **Prefers CDI when present:** Hand-written CDI specs work identically. Intel ships a generator (cdi-specs-generator); proven: a 41-line intel.com/gpu spec maps the FULL bundle (card1 + renderD128 + by-path symlinks the Intel UMD needs). Fall back to raw DRI render node if absent.
- Other substrates:
  - LXC: cgroup device-allow + /dev/dri mount (Proxmox pattern)
  - KVM/bhyve exclusive: VFIO/ppt (not yet built)
  - jail: devfs ruleset
  - bwrap: `--dev-bind`

**Check-time allocation rules:**
1. `exclusive ∩ anything` on one device → FAIL `aeo check` with reasoning ("exclusive passthrough removes the device from the host; move shared consumers to container tier or pin a second device"). Human tier-choice becomes machine-checked constraint.
2. Capability gating per kind at check, not deploy-time surprise.
3. Host preflight probes device exists (/dev/dri/renderD*, nvidia nodes).

### Status

- **BUILT:** compose: `gpu()`/`gpu_device()`/`get_gpu_mode`/`get_gpu_device`/`gpu_flags(+cdi_dev)`/`gpu_alloc_error`
- Runner: up-path probes /etc/cdi, splices gpu_flags into confine, `aeo check` runs gpu_alloc_error()+_gpu_preflight()
- `describe_tree` shows gpu=
- test/spec_gpu.ae (14 test cases)
- **Live on Intel N100:** Both the CDI arm (`intel.com/gpu=all` → full card+render+by-path bundle) and raw-DRI fallback (`renderD128`)
- **NOT yet built:** VM exclusive/VFIO render (refused-at-check today, honest); `--gpus` path (that flag fails on Intel anyway)

### Design Benefit

Allocation semantics surface at composition time. The architecture decides whether to share a device or monopolize it; aeo enforces the contract.

---

## H. PROPOSED: `nested_virt()` — Deny-by-Default, Attenuate Down Tree

**Status:** Proposed 2026-07-04, not built.

### The Problem

A node with nested virtualization can stand up its own hypervisor — sub-VMs aeo can't see — breaking tree-is-truth, dodging structural limit{} accounting, and riding historically buggy nested-VMX. It's the compute-capability twin of `deny_egress`.

### Doctrine

**Capability must ATTENUATE down the containment tree; it never flows down implicitly.** A node that legitimately needs children should DECLARE them in the composition (aeo-agent delegate path), not get raw `/dev/kvm` to freelance — deny-default forces sprawl INTO the tree, where it's orchestrated/confined/audited.

### Grammar

Explicit per-node grant (peer of `limit{}`, `constrain{}`):

```aether
nested_virt()  // Enable nested virt for this node only
```

Semantics:

1. **Deny = ACTIVE masking**, not passive absence — even when substrate defaults leak it (host-passthrough CPU exposes vmx/svm): `-cpu host,-vmx,-svm` on child VMs; no /dev/kvm mapping + cgroup device-deny for containers/lxc; `[wsl2] nestedVirtualization=false` for WSL tier.

2. **No float-down** — unlike `health_retry`, the grant does NOT inherit; every level re-declares. Attenuation by default, amplification never.

3. **Check-time CHAIN validation** — can't grant what ancestry lacks: host kernel `nested=1` → VM has vmx → container maps /dev/kvm; a break anywhere fails `aeo check` with the chain spelled out. (Live scar tissue: Bazzite → Win11 → WSL2 → podman 3-deep needed each layer enabled manually; guest's "wsl: Nested virtualization is not supported" was a masked layer observed in the wild.)

4. **Refused where ungrantable** — `nested_virt()` on firecracker (no device model) or jail = check error, honest.

5. **Audited** — a virt grant is a security event in the hash chain, like attest/confine.

For containers, the grant is a device grant (`/dev/kvm` is a kernel object — same vocabulary as `gpu()`). The contract name stays mechanism-free per the naming rule (CPU-flag mask vs device map vs wslconfig varies per substrate, belongs to drivers).

---

## I. PROPOSED (Idea Sweep): Journaling, Witnessing, Replication, Failover, Blue-Green Slider, Router Grammar

**Status:** Idea sweep 2026-07-04, none built; cranker follow-up owed.

### Context

Paul's prompt: go wide — journaling (WAL orchestration), witnessing (quorum + attestation), active replication (with health), failover (fencing via confinement), blue-green with human percentage slider, router grammar (traffic element, named honestly), and supply-chain attestation (proxy-side). Unifying observation: most are **CONNECTOR TYPES** — standing relationships deserve first-class grammar. No verb without a check.

### 1. Journal: Write-Ahead Logging for Orchestration

```aether
journal() { retain(30d) sink(...) }
```

Payoffs:
- Interrupted `aeo up` RESUMES from the journal
- Journal-vs-live drift is detectable
- Existing hash-chained audit widens from security decisions to lifecycle events
- Check: chain integrity (`aeo audit`); replay reconstructs status

### 2. Witness: Quorum + Attestation

```aether
witness("w1") { observes("db") apart_from("db") }
```

Two flavors:
- **Quorum witness:** Tie-breaker voter, prevents 2-node split-brain
- **Attestation witness:** Observes peers' health/attest streams, keeps its OWN signed journal — two independent hash chains that must agree; divergence = tampering or partition; non-repudiation for the orchestrator itself

Check: witness co-located with subject = error → requires FAILURE DOMAINS as supporting grammar (`domain("rack1")` / `apart("a","b")` — cheap, foundational).

### 3. Replication Link: First-Class Edge with Health

```aether
replication { from("db-1") to("db-2") lag_within(5s) }
```

The replication LINK as a first-class edge with its own health (replicas alone can't order a failover — never declared who replicates whom).
Check: failover refuses to exist without declared edge; lag probed.

### 4. Failover: Fencing = Confinement

```aether
failover("db") { primary(...) standby(...) witness(...) promote_within(30s) manual() }
```

aeo's unfair advantage: **FENCING = CONFINEMENT**. The step everyone bolts on (STONITH agents), aeo already owns: fence the failed primary with `deny_egress` + halt — existing containment grammar applied posthumously.

Check: quorum arithmetic (2 voters need a witness); primary/standby in different domains; replication lag was in bounds.

### 5. Cutover (Blue-Green): Human Slider + Audited Position

```aether
cutover("app") { blue(...) green(...) weight(0) slider() guard(spec) }
```

The human-slider blue-green (strictly: weighted canary with a human hand, the better thing). `aeo weight <file> app 25` moves it live.

aeo-flavored:
- The slider is an AUDITED runtime input (who/when, hash-chained)
- Slider position is journal state — survives restarts
- Green is ineligible for weight>0 until declared `smoke()` spec PASSES — check/smoke/suite verbs become the promotion gate

### 6. Router: Traffic Element, Named Honestly

```aether
router("edge") { ingress(443) route("/", "app") route_weighted(...) }
```

The traffic element (app-runner-router / mu-cranker-router lineage; "reverse proxy" describes packet topology, not role).

**THE CHECK THAT EARNS IT:** Only router() nodes may hold public ingress — any other node with internet-facing ingress fails `aeo check`. North-south enters via declared edges or not at all: an architectural invariant, machine-enforced.

Also from the Flower set: 
- **egress_via("guard"):** All outbound through declared caching/attesting proxy node (auditable egress, deterministic fetches, supply-chain attestation AT proxy)
- **aeo migrate:** Composes replicate → cutover → retire
- **Actual-vs-limit gauges:** `aeo status` grows real measurements

### 7. Cranker Seed: The App-Side Connector

**Follow-up promised (see Section J).**

The "reverse reverse proxy": app-side connector DIALS OUT to router, registers, requests flow back down the connection, app NEVER LISTENS (NAT-friendly, zero ingress).

This is the resident-agent doctrine applied to the DATA PLANE: **EVERY node can carry worker posture** (deny_ingress everywhere) **and still serve** — only routers hold sockets.

```aether
worker("app") { container("app"){...} serves_via("edge") }
```

A tree that is deny-ingress except declared edges = strongest containment posture an orchestrator ships by default.

### Priority

1. **Domains/anti-affinity + journal** (foundations: cheap, everything leans on them)
2. **Router + cutover/slider** (most visible, exercises smoke gate)
3. **Replication + failover + witness** (deepest design risk, last)
4. **Cranker/serves_via** (follow-up discussion)

---

## J. CRANKER FOLLOW-UP (2026-07-04): Two-Part Registration — The Injected Channel

**Status:** Design discussion recorded; aeo-agent = connector host decided; not built.

### Framing

Cranker lets a child register with a parent router to receive web traffic as part of a cluster; principles of containment ordinarily forbid a child finding/dialing a parent's port-listener — but a channel can be **EXPLICITLY INJECTED** into the child by the grammar, making an effective **TWO-PART REGISTRATION**.

### Confirmed from Upstream

mu-cranker-router + cranker-connector READMEs:
- Registration IS over WebSockets (wss://; connector config = router URL(s) via DNS or fixed, withRoute("path-prefix"), local target URI)
- Router holds TWO listeners (public HTTPS + separate registration WSS server)
- HTTP semantics maintained over tunnel
- Live websocket IS the liveness signal
- Graceful drain built in (stop(timeout) deregisters, waits in-flight)
- **Registration auth is BYO** — operators bolt on firewall/mTLS/basic-token protection → the composition should supply first-class

### The Two-Part Registration

The agent's addressing doctrine ("the contained never told me where it lives; I assigned it") applied to the data plane.

**Part 1, declaration time (aeo acts; child passive):**
1. Mint per-child registration secret (agent_auth.mint_secret — exists)
2. Provision the EXPECTATION on router: route ↔ HMAC binding ("accept connector for /api bearing this; nothing else for /api")
3. Inject into child at launch: `AEO_SERVE_URL`/`ROUTE`/`TOKEN` — assigned, never discovered
4. Render netpolicy: child egress-allow to EXACTLY edge:registration-port, deny-all else — declared flow punched through confinement, not a hole in it

**Part 2, runtime:** Connector dials wss out, presents token+route; router verifies against provisioned expectation; mismatch → refused + audited. Route hijack structurally impossible: you can only register what was granted.

### Grammar

```aether
router("edge") { ingress(443) registrations(8008) }
worker("app") {
    container("app") { image("…") }
    serves_via("edge", "/api")
}
```

Checks:
- `serves_via` must target a `router()`
- Node must have NO `ingress()` (the point — error otherwise)
- Same route on N nodes = load-balanced set (deliberate, cranker cluster behavior)
- `serves_via` may name router SET (HA — "one or more routers" confirmed)

### What Falls Out for Free

- Probe path never touches node (router's registration table as health source — connection-is-liveness)
- `aeo drain` = stop(timeout) semantics (deregister → in-flight → halt; down_within = drain timeout)
- Blue-green slider's mechanism (v1+v2 register same route, router weights between registration groups)
- Agent/connector answer: same dial-out shape + courier doctrine, DELIBERATELY different secrets/endpoints (control vs data plane must not share compromise), agent COURIERING connector credential

### Responsibility Assigned

aeo-agent sets up active cranking (2026-07-04):

1. **Sidecar, not library:** Stock cranker is a Java library the app embeds; agent-hosted cranking means WORKLOAD IS UNMODIFIED (just serves localhost). Agent maintains wss registration pool beside it.

2. **Control plane bootstraps data plane:** Delegate message over authenticated agent channel carries serves_via grant (route + router endpoint + minted token); agent stands up data channel. Attenuation preserved.

3. **Attest gains data-plane axis:** Agent's self-attest answers "am I registered at edge for /api and NOTHING else?" — drift between declared and actual routes is an attest failure from inside the boundary.

4. **Ordered teardown built in:** halt → agent drains FIRST (deregister, wait in-flight) → stops workload. down_within = drain window.

5. **Supervision:** Re-registration on router restart, pool replenishment, registration liveness folded into agent's status reporting: parent learns "up AND serving" through one channel.

### Implementation Notes

**Framing protocol to confirm before implementing:** V1 idle-socket-pool vs V3 multiplex (from prior knowledge, unconfirmed in README).

---

## Research Value

This document captures the design thinking behind:
- **Section D (BUILT):** Why `container()` + `engine()` is the right factorization, not a one-to-one per-runtime
- **Section E (OPEN):** How nesting on LXC/nspawn becomes general via the exec seam, not VM-specific
- **Section F (OPEN):** How to make architectural intent (`service`, `worker`) compile-time checkable
- **Section G (BUILT):** How `gpu()` allocation semantics surface at compose time, preventing runtime surprises
- **Section H-J (PROPOSED):** The connector-type thesis and how it applies to failover, replication, routing, and registration

These patterns inform future development and help others understand the reasoning behind decisions.
