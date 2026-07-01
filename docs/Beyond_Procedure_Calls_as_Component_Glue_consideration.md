# *Beyond Procedure Calls as Component Glue* — a consideration for aeo

A read of Weiher, Taeumel & Hirschfeld, **"Beyond Procedure Calls as Component
Glue: Connectors Deserve Metaclass Status"** (Onward! '24,
[doi:10.1145/3689492.3690052](https://doi.org/10.1145/3689492.3690052)),
against aeo — an infrastructure orchestrator whose thesis (*config IS code*, for
a live containment tree) is the paper's, applied.

**In one paragraph:** the paper argues that architecture should be expressed
*in* the implementation via a small set of polymorphic connectors, not encoded
indirectly through procedure calls or maintained as a separate ADL. aeo is that
argument applied to live infrastructure — one Aether composition you *run* stands
up a confined tree of compute nodes, no YAML. From the paper's directions aeo
built: a resident in-node agent that makes the containment tree *execute*
recursively (host → VM-agent → container-agent, live on real KVM); a bank-courier
authenticated channel (a hand-carried key, not PKI) as the standing connection;
self-attestation, where the resident deputy re-checks its own confinement from
inside the boundary; and eight substrate variants behind one shared connector.
Where the paper's elegance is a trap for a *containment* system — a general
polymorphic-connection operator, reaching *through* a boundary, guest-side
enforcement — aeo declines, on stated grounds. §4 is the one genuine divergence
worth Dave Thomas's eye: aeo reverses the paper's reach-into-the-contained on
Principles-of-Containment grounds. The honest open edges: TLS on the agent wire,
and one FreeBSD networking bug unrelated to the paper.

Companion to the "Academic precedent" note in `LLM.md`; `docs/aeo-agent.md` is
the agent design, live-proven.

---

## 1. What the paper is

Objective-S is an "architecture-oriented" language. Its thesis: general-purpose
languages are *architecturally monomorphic* — they bake in exactly one connector
(the procedure call) and force every other architectural relationship (a pipe, a
REST call, a directory sync, an event) to be **encoded indirectly** through that
one connector. That indirection is the cost. The paper's fix is to make
connectors **polymorphic** via a metaobject protocol, exposed at the surface by a
single connection designator `→`, so the architecture *is* the implementation —
no separate ADL, no YAML, no duplicate representation to keep in sync.

The load-bearing claims, with the listings that demonstrate them:

- **One program, substrate-portable, local/remote differ by a handle.**
  Listing 41 is directory-sync-as-a-program (`#sync:<ref>source to:<ref>target`).
  Listing 42 is the *remote* case — and the paper states outright (§5.6) that
  "the main difference between the remote case and the local case in listing 41
  is the use of an `SSHConnection` to obtain a store representing the remote
  filesystem." The composition is otherwise identical.
- **No packaging mismatch.** §8.7 (Plan 9): an abstraction mediated by the OS
  rather than the language "requires serialized representations, which have to be
  parsed, generated and accessed via the POSIX APIs … a form of packaging
  mismatch." This is the academic statement of *why you don't route config
  through YAML-over-a-CLI*.
- **Connector ≠ its variant.** Table 1 separates connector *types* (a handful)
  from their *variants* (many); §7.1 reports the empirical finding that distinct
  connector types are few even when components are many — so giving the few types
  first-class language support is tractable.
- **The mechanism is protocol + replaceable transport.** The `→` operator is thin
  surface over a metaobject protocol; the same verbs work across stores whose
  transport differs (in-memory, file, SSH, HTTP).

## 2. Why it's directly relevant to aeo

aeo's whole pitch (LLM.md §"What aeo is for") is **config IS code** applied to
*live* infrastructure: one Aether composition stands up a tree of compute nodes,
no YAML ever. The paper is the canonical academic backing for exactly that
stance, and — uncommonly — it uses **infrastructure** as its worked example
(L41/L42 are directory orchestration; L44 wires an HTTP server to a store with
`→`). It is "config-IS-code-for-infra," argued rigorously, two years before aeo.

So the paper is a *precedent to cite*, not a dependency to import. The
interesting part is not where aeo agrees with it (that's the easy 90%) but the
**two places aeo deliberately diverges**, because those divergences are aeo's
actual contribution.

## 3. Where aeo already matches the paper (often without trying)

aeo independently reinvented the paper's best structural idea. `lib/protocol/`
is a small, stable verb set (`boot`/`halt`/`probe`/`announce`/`report`) with a
**replaceable transport beneath it** (`lib/transport_file/` in use; a drafted
`lib/transport_http/` on `std.http.server`). The module header says it in nearly
the paper's words:
"the verbs + fields are the stable contract; the transport under them is
replaceable." That is a metaobject protocol in miniature — the connector
factored cleanly from its variant, exactly as Table 1 prescribes.

And `aeo-agent` *is* the paper's "standing live connection." The paper's `→`
defines a connection that exists for its lifetime (a breakpoint on `→` fires
whenever communication occurs over it — §3). aeo's runner already drives local
resources as actors with `Boot`/`Probe`/`Halt`; `docs/aeo-agent.md` makes the
agent "the same actor protocol, one boundary down," with the runner as just the
depth-0 agent. Same recursion, same protocol-uniform substrate-portability the
paper claims for `→`.

## 4. The two deliberate divergences — aeo's contribution over the paper

### 4.1 A resident deputy with no workload surface — not "the contained talks back"

This is the big one, and it's easy to state backwards. First, what the paper does:
L42 is **remote directory sync over SFTP** — an `SSHConnection{ host:, user: }`
yields a store for a *remote filesystem*, and `|=` syncs against it. There is no
"guest," no "contained," no isolation boundary in the paper at all; it just
reaches a remote machine's files, holding the credentials.

Now the containment model, stated correctly (per
[The Principles of Containment](https://paulhammant.com/2016/12/14/principles-of-containment/)):
**a container orchestrating the thing it contains is entirely legitimate, and
always was** — reaching in to boot/halt/configure the contained is what authority
over the contained *means*. What containment forbids is the **contained's own
workload chatting back up on its own terms** — the contained process declaring
"actually I'll have four more deps please," negotiating, initiating conversation
with its container. The contained gets what the container gives it; it does not
renegotiate.

So the interesting property of aeo is **not** "aeo reverses the flow so the
contained talks back" (that would be the *violation*). It is that `aeo-agent` is
the **container's deputy, resident inside the node**: it enacts the container's
will and reports health, but it exposes **zero ABI surface** to the node's other
processes — the workload (Python code, whatever runs there) gets no channel to
the parent through it. The agent serves the container, never the workload; the
workload "only suspects it is contained" and has no means to reach out. The agent
*physically* dialing out to report is a transport detail, not the contained
negotiating — because the agent acts for the *container*, and the workload can't
speak on its channel.

What makes "no workload surface" enforceable rather than aspirational: the
parent↔agent channel runs over TLS and is authed by a **one-time symmetric secret
the bootstrap ssh hand-couriers in — the 1970s bank-courier model, no CA, no
keypair, no trust root** (design-intent; see `docs/aeo-agent.md` §"Channel
security"). The workload can't forge onto the channel because it lacks the
couriered secret, and there is no issuer to mis-issue against. Single-parent
enforcement
falls out of "one key pair, no authority above it."

This is a containment property the paper neither has nor needs (Objective-S isn't
a containment system) — but the contribution is the *resident-deputy + no-surface*
shape, not a directionality flip that lets the contained speak freely.

### 4.2 No `→` operator, no general MOP at the front door

aeo's front door has no polymorphic connection operator and shells out to `aeb`
for static structure (the static DAG is aeb's job — LLM.md §"aeo is NOT aeb").
The agent's protocol is a *deliberately narrow* MOP (five verbs over one
transport seam), not Objective-S's general one. aeo gets the runtime layer the
paper describes without taking on a general connection abstraction that would
blur the aeb/aeo seam.

## 5. What aeo built from the paper's directions

The paper legitimized a set of directions; aeo built them. Each respects the
aeb/aeo factoring and the resident-deputy containment model (§4.1), and each is
live-proven on real hardware (a rootless Fedora-atomic "Bazzite" box with KVM).
This is the paper's ideas *realized*, not planned.

### 5.1 Recursion — the containment tree executes

The agent is depth-agnostic: an agent whose booted node has `get_host` children
brings *those* up through the same protocol it received its own work through, so
a parent hands work *down* to a resident child agent that becomes the local
orchestrator for its subtree. Two levels prove N by construction, and both run
for real: a plain `aeo up examples/agent_nested_min.ae` stands up
grandparent(aeo host) → parent(agent in a KVM VM) → child(agent in a container
nested in that VM), zero manual steps (`aeo: [vm] up / [ctr] up / stack up`).
This is the Principles-of-Containment "nesting" row moved from *declared + gated*
to *executes* — the build the agent architecture exists for.

### 5.2 The bank-courier channel — auth as a hand-carried key, not PKI

The parent↔agent channel runs over `std.http.server` (not ssh — ssh is
bootstrap-only, the "motorbike"), fail-closed: `/dispatch` and `/ping` return 401
on a bad/absent token; `/health` stays open as the residence probe. Auth is the
**1970s inter-bank key courier**, not PKI: the bootstrap session hand-delivers a
**one-time symmetric secret** (minted per agent from `std.cryptography.drbg`,
dead when the agent dies), and the standing HTTP channel authenticates against it
with a constant-time `std.cryptography.hmac` compare. No CA, no keypair, nothing
to pin — the `contrib/cryptography` asymmetric suite (ed25519/rsa/x25519, even
ML-KEM) is deliberately unused; the symmetric pre-shared key *is* the design.
This is the paper's "connector, not its variant" applied to authentication: a
small stable protocol with a hand-carried key beneath it. (One thing is designed
but not yet on the wire: TLS for channel confidentiality — `std.http.server`'s
h2-TLS with an ephemeral self-signed cert; identity is already the couriered key.)

### 5.3 Self-attestation — the resident deputy re-verifies its own confinement

The resident agent is the only thing that can re-attest a node's confinement
**from inside the boundary** — the orchestrator is outside and cannot see in. The
`attest` verb does exactly this and reports `ok` / `drift:<axis>` outward: a node
declared `deny_egress` must genuinely have no route out, so if the agent *can*
reach the outside, confinement has drifted (`drift:deny_egress`) — the exact
signature of an attacker who escaped the network policy. The egress probe is
in-process (`std.net.tcp_connect_raw`), so the deputy doesn't depend on the
guest's toolage to attest itself. This is the concrete, useful form of the
paper's "standing live connection": a connection whose whole job is to keep
checking that containment still holds. More axes (image digest, cgroup caps) slot
in behind the same verb.

### 5.4 (Not a paper item) — the one honest gap: FreeBSD `if_bridge`

Stated plainly so this reads as an honest assessment, not "all green": the single
red containment axis is host-pf inter-VM confinement on FreeBSD, blocked by a
pre-existing `if_bridge` networking bug with no connection to this paper. It is
tracked separately (`docs/if_bridge-pf-delivery-bug.md`). The Linux per-flow
netpolicy is live-proven and sidesteps it; the paper does not speak to it. (Noted
too as the reason NOT to let the paper's guest-side stores tempt guest-side
*enforcement*, which would invert the containment trust boundary — §6.5.)

### 5.5 One connector, many substrate variants — Table 1's shape, realized

aeo's eight driver tiers (containers/lxc/kvm/jail/bhyve/bwrap/nspawn/firecracker)
are not eight *connectors* — they are variants of a handful of confinement
*types* behind one shared connector, which is exactly §7.1's empirical finding
(few connector types, many variants). By confinement boundary the tiers reduce to
~five types: process-sandbox (`bwrap`), OCI container (`linux`), system container
(`lxc` + `nspawn`, two variants of one type), full VM (`kvm` + `bhyve`, already
one `driver_vm`), and microVM (`firecracker`), with `jail` a system-container-
class type on a different kernel primitive. The *connector* over all of them is
single and stable: every tier goes through the same `up/down/probe/exec` driver
interface, the same `delegate`/`status`/`attest` agent protocol, and the same
`limit{}` + `constrain{}` confinement grammar (which itself renders to FreeBSD
rctl/Capsicum/pf **and** Linux cgroups/seccomp/network — one vocabulary, many
substrates). This is Table 1 made concrete: hold the connectors few and shared,
let the variants be many and honest. Collapsing the drivers themselves would
trade real per-substrate code for a leaky mega-driver — so the paper's
prescription is satisfied by keeping them separate behind the one connector.

## 6. Directions the paper makes seductive — should NOT do

The paper's elegance is a trap in two specific places. Naming them so a future
session doesn't mistake omission for oversight.

### 6.1 Do NOT add a `→` operator or connection-as-first-class-object to the front door

The `→`+MOP is genuinely elegant and a future reader *will* be tempted to give
aeo a general polymorphic connection abstraction. That is the
**aeo-becomes-aeb failure mode in a new costume** (LLM.md §"aeo is NOT aeb"): a
general static connection over artifacts is aeb's grain, not aeo's. The agent's
five-verb protocol is the *only* connection abstraction aeo should have, and it
lives one boundary down (in the node), not at the front door. Keep the front door
imperative-runtime with health-gated handles.

### 6.2 Do NOT build an SSH-into-the-guest remote driver (prefer the resident deputy)

To be precise — the objection is *not* "the container must never reach into the
contained"; orchestrating the contained is legitimate (§4.1). The objection to an
SSH driver that dials into a guest and runs `podman` there is narrower and still
decisive: it makes aeo hold **long-lived guest credentials** and carry a standing
**interior network path** that the contained workload shares — and it gives no
resident deputy, so no *no-workload-surface* and no one-time-key guarantee. The
`aeo-agent` deputy gets the same orchestration done with **no standing
credentials** (one-time keys, minted per agent, dead when the agent dies) and
**zero surface to the workload**. So: same authority over the contained, none of
the credential/interior-reach liabilities. Prefer the deputy; don't keep an
ssh-in driver as a fallback. (Distinct from ssh's legitimate one-shot use:
*bootstrapping* the agent in — push + launch, session closes — after which the
standing channel is the agent's HTTP socket, no held credentials. A standing
ssh *orchestration* driver is the should-not; ssh-as-installer is fine.) In the
paper L42 is harmless remote-filesystem sync; this concern only arises across a
containment boundary.

### 6.3 Do NOT add a config-file parser to "match" the paper's stores

The paper's stores (file/SSH/HTTP) can tempt a "just parse a remote YAML/JSON
store" shortcut. §8.7 is the argument *against* this: serialized-representation +
POSIX-API access is the packaging mismatch aeo exists to avoid. External formats
only via shell-out (LLM.md §"DSL conventions"). The composition stays `.ae`.

### 6.4 Do NOT chase the paper's performance/native-compiler framing

§7.3 (Objective-S as a fast web server, native compiler) is interesting but
orthogonal — aeo's value is orchestration + containment, not request throughput.
Don't let the benchmark sections pull aeo toward being a runtime/server. Wrong
axis of merit.

### 6.5 Do NOT let the paper's guest-side stores tempt guest-side *enforcement*

The paper happily puts stores *inside* the guest (file/SSH/HTTP) and reaches them.
For a containment system that is fine for *reporting* (the resident deputy reports
health on the container's behalf) but must NOT slide into *enforcement* (a guest
firewalling itself). Host-pf does the denying; a compromised guest must not be
able to disable its own confinement.
This is the live temptation for the FreeBSD `if_bridge` red axis — solving that
bug at the host is the job, not pushing netpolicy into the guest. (Bug planned in
`docs/if_bridge-pf-delivery-bug.md`.)

## 7. One-line takeaway

aeo and the paper share a thesis (config IS code, connector ≠ variant, protocol
over replaceable transport). aeo's contribution on top is the **resident-deputy
containment model** — the container's agent lives inside the node, enacts the
container's will and reports health, exposes zero surface to the workload, and
holds no standing credentials (an ssh-couriered one-time symmetric secret — the
bank-courier model, no CA). aeo built the directions the paper legitimizes:
the containment tree *executes* recursively, the bank-courier channel authenticates
the standing connection, the resident deputy self-attests its own confinement,
and the eight substrate variants sit behind one shared connector. It declined the
directions the paper makes seductive-but-wrong: no `→`/general-MOP at the front
door, no ssh-into-the-guest driver (§6.2), no guest-side *enforcement* (§6.5) —
the front door stays narrow, enforcement stays at the host. Two things remain
honestly open: TLS on the agent wire (designed, not yet on the socket), and the
FreeBSD `if_bridge` red axis (a pre-existing aeo networking bug unrelated to this
paper — `docs/if_bridge-pf-delivery-bug.md`).
