# *Beyond Procedure Calls as Component Glue* — a consideration for aeo

A read of Weiher, Taeumel & Hirschfeld, **"Beyond Procedure Calls as Component
Glue: Connectors Deserve Metaclass Status"** (Onward! '24,
[doi:10.1145/3689492.3690052](https://doi.org/10.1145/3689492.3690052)),
against where aeo actually is — and what it says we should and should not build
next.

Status: assessment doc, ae 0.328 (2026-06-30). Companion to the
"Academic precedent" note in `LLM.md`. Read `docs/aeo-agent.md` and
`docs/pf-enforcement-next-steps.md` alongside this.

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
parent↔agent channel is encrypted + mutually authenticated with **one-time
per-agent keys — no CA, no trust root** (design-intent; see `docs/aeo-agent.md`
§"Channel security"). The workload can't forge onto the channel because it lacks
the key, and there is no issuer to mis-issue against. Single-parent enforcement
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

## 5. Directions the paper *legitimizes* — SHOULD do

Ranked by leverage. All respect the aeb/aeo factoring and the resident-deputy
containment model (§4.1).

### 5.1 Land the recursion — the headline build

Today's agent (`bin/aeo-agent.ae` v0) boots a *single* node and reports out. The
entire thesis is **depth-agnostic recursion**: an agent whose booted node has
`get_host` children hands *those* to *their* agents — same code it received its
own work through. Proving **two levels** (a container inside a VM, the VM's agent
booting the container's agent) proves N by construction. This flips the
Principles-of-Containment "nesting" row from *declared + gated* to *executes*.
Highest leverage available; it's the build the agent architecture exists for.
(`docs/aeo-agent.md` build steps 2–4.)

### 5.2 (Not a paper item) — the FreeBSD `if_bridge` red axis

For completeness: the one red containment axis (host-pf inter-VM confinement on
FreeBSD) is a **pre-existing aeo networking bug** with no connection to this
paper. It is the credibility gap and outranks the feature work below, but it is
*not* something the paper speaks to, so it is planned separately in
**`docs/if_bridge-pf-delivery-bug.md`** (with `docs/pf-enforcement-next-steps.md`
and `docs/bhyve-networking-journey.md`). Mentioned here only so this assessment
isn't read as "all green" — and as a reminder NOT to let the paper's guest-side
stores tempt a guest-side-enforcement side-step (that inverts the containment
trust boundary; see §6.5).

### 5.3 Move `transport_http` auth from bearer-token to one-time-key mutual auth

Most of this is already drafted. `lib/transport_http/` (on `std.http.server`,
**not** ssh — ssh is bootstrap-only) is **fail-closed** today: `/dispatch` and
`/ping` return 401 on a bad/absent token, `/health` stays open as the residence
probe. The remaining work is the *auth shape*: today it's a **bearer token in the
request body** (a shared secret); the §4.1 target is **one-time per-agent keys,
no CA / no trust root** — a freshly-minted keypair the parent pins at bootstrap,
mutual-auth on it, dead when the agent dies. Single-parent enforcement falls out
of "one key pair, no authority above it," and the no-workload-surface property
becomes cryptographically enforceable (the workload lacks the key). So this item
is not "build transport_http" — it's **move transport_http's auth from
bearer-token to one-time-key mutual auth.** Self-contained and scoped.

### 5.4 Agent-side self-attestation (the paper's "standing connection," used)

`probe` already exists in the protocol. A *resident* agent is the only thing that
can re-attest its own subtree **from the inside** — image digest still matches,
`constrain{}` still in force, `deny_egress` still has no route — and `report` it
outward. The orchestrator can't see inside the boundary; the agent can. This is
containment drift-detection that only the agent architecture makes honest, and it
is the concrete, useful form of the paper's "standing live connection."

### 5.5 Treat the agent's protocol as the tier-unifier (housekeeping)

With ~8 driver tiers (containers/lxc/kvm/jail/bhyve/bwrap/nspawn/firecracker),
the agent's "same actor protocol, different transport" is the abstraction that
lets tiers compose *behind* one selector rather than proliferate. §7.1's finding
(few connector types, many variants) is the warrant: audit whether new tiers are
genuinely distinct *confinement* types or variants that should collapse. Also
sync `docs/aeo-agent.md` (it says "not yet built" while `bin/aeo-agent.ae` is a
working v0 — a credibility footgun against the proven-vs-modeled discipline).

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
over replaceable transport) and aeo's contribution is the **resident-deputy
containment model** — the container's agent lives inside the node, enacts the
container's will and reports health, but exposes zero surface to the workload and
holds no standing credentials (one-time keys, no CA). The work the paper
*legitimizes* is finishing the agent (recursion, fail-closed one-time-key
transport, self-attestation). The work it makes *seductive but wrong* is importing
`→`/general-MOP to the front door, an ssh-into-the-guest driver (§6.2), or
guest-side *enforcement* (§6.5). Build the agent out; keep the front door narrow;
keep enforcement at the host.

*(The FreeBSD `if_bridge` red axis is the higher-priority infra task overall, but
it is a pre-existing aeo bug unrelated to this paper — planned in
`docs/if_bridge-pf-delivery-bug.md`, not here.)*
