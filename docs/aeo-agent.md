# aeo-agent — orchestration that recurses through the containment tree

Status: **BUILT and live-proven on real KVM** (2026-07-01). The model below —
nested / substrate-crossing orchestration (a container inside a VM inside a host)
that the flat driver model can't reach — is implemented and converges end to end:
a plain `aeo up examples/agent_nested_min.ae` (with `AEO_AGENT_PATH=1`) stands up
grandparent(aeo host) → parent(agent in a KVM VM) → child(agent in a container
nested in the VM), zero manual steps (`aeo: [vm] up / [ctr] up / stack up`). It
supersedes the earlier "step into the guest over ssh" framing — that was the
wrong directionality; the resident deputy replaces it.

**Proven vs. modeled (honest):**
- ✅ Recursion (`delegate`), the depth-agnostic protocol, both transports
  (file + http), bank-courier auth (CSPRNG mint + constant-time HMAC verify,
  fail-closed), async delegate (fire-in-background + `status` poll),
  self-attestation (`attest` → deny_egress drift), and the full `aeo up` join —
  all live on the Bazzite box.
- ⬜ Modeled/opt-in still: the agent path is behind `AEO_AGENT_PATH=1` (ssh path
  is the default until it's blessed); boots are `AEO_BOOT_NOOP` (the tree
  converges — no real workload in the child yet); TLS on the socket is designed
  (§"Channel security") but the wire is plaintext-under-a-couriered-token today;
  depth is proven at two levels (N by construction).

The rest of this doc is the design; where a section still says "next" / "when we
get to it," read it as the original plan — most of it is now the shipped path.

## The one sentence

**The container hands its contained an `aeo-agent`, and that agent carries
orchestration deeper: it receives the instructions for its own node and for
everything nested below it, brings its node up, and in turn hands instructions
to the agents of its children.** The orchestrator never reaches *through* a
boundary; at each level a parent hands instructions *down* to an agent that
already lives *inside*, and that agent becomes the local orchestrator for its
subtree.

## Why an agent, not ssh

The obvious way to "create a container inside the running VM" is for aeo to
`ssh` into the guest and run `podman` there. That **violates the Principles of
Containment** (paulhammant.com/2016/12/14/principles-of-containment): the
container reaching down into the contained's innards is the LiveConnect /
DOM-monkey-patching antipattern the post calls a disaster. It also forces aeo
to hold guest credentials, have network reach into the interior, and know the
guest's internals.

`aeo-agent` inverts it to the correct directionality:

- **The agent is the container's deputy *inside* the node — not the contained
  talking back.** This distinction is load-bearing. Containment *always* allowed
  the container to orchestrate the contained; what it forbids is the *contained's
  own workload* opening chat upward ("actually I'll have four more deps please").
  The agent is **not** that: it enacts the outer container's will (boot/halt/probe)
  and reports health, but it exposes **zero ABI surface** to the node's other
  processes — the Python workload (or whatever runs in the node) gets no channel
  to the parent through the agent. The agent serves the container, never the
  workload. On boot it dials the parent ("I'm `app`, up, here's my health") — a
  *report* on a single pre-configured endpoint, not a negotiation. The workload
  "only suspects it is contained" (the post's phrase) and has no means to reach
  out at all.
- **The parent messages IN to a resident agent, not through the boundary.**
  aeo doesn't push commands across the kernel boundary; it sends a message to
  an agent already inside, which acts locally. The boundary is crossed by a
  *message to a resident*, never by reaching through.

## Depth-agnostic by construction

Every node sees the **same** shape regardless of depth:

```
        [ parent hands instructions down ]
                      │
                   ◄ node ►   ← an aeo-agent: receives its instructions,
                      │          brings its node up, reports up
        [ hands instructions down to children ]
                      │
              ◄ child ► ◄ child ►   ← each an aeo-agent, recursing
```

No node knows its nesting depth, because the protocol is identical at every
level: an agent above hands you instructions; you bring your node up; if you
contain anything, you hand *those* instructions to *your* children's agents.
This is exactly the post's "each contained item further restricted without
knowledge of its nesting depth" — the agent is the unit that makes it true.

## It's the actor model, one level down

aeo's runner already drives local resources as actors with `Boot` / `Probe` /
`Halt` messages (lib/aeo/runner.ae). `aeo-agent` is **the same actor protocol,
one boundary down**:

- A resource is driven either **locally** (the host driver: jail/container/vm)
  or **via its in-guest agent** — same message types, different transport.
- The agent inside a VM is, to its own children, what the top-level runner is
  to its top-level resources. The runner and the agent are the *same program*
  playing the role at different depths.
- So the dispatch becomes uniform: `driver_up(nm)` for a top-level/local node;
  `agent_send(host_of(nm), Boot{nm})` for a nested node. `get_host(nm)` (which
  already exists — the `inside` relationship) is exactly the routing key:
  empty → drive locally; non-empty → hand to that host's agent.

## How the agent gets in, and learns who it is

- **Getting in** — bake it into the guest. The **inline `dockerfile()`** just
  landed is the vehicle for containers: `RUN install aeo-agent` / `COPY`. For
  jails it goes in the populated root (the `provision` step); for VM images
  it's in the image (or dropped via cloud-init / the VM's first-boot
  `command`). aeo-agent is a tiny Aether binary — a natural `--emit=lib` or
  small static exe.
- **Bootstrap identity + rendezvous** — on boot the agent needs to know (a)
  *which orchestrator* to dial and (b) *which node it is*. Candidates: an env
  var / cloud-init datum aeo sets when it boots the host (`AEO_PARENT=<addr>`,
  `AEO_NODE=app`), the resource's `command`, or a well-known rendezvous the
  parent advertises. The parent already knows the child's identity (it
  declared it), so it can stamp it at boot time.

## Addressing — the courier stamps the port; the contained NEVER self-addresses

A containment rule, not a networking detail: **the container dictates where the
contained listens; the contained never announces its own address.** A child
telling its parent "I'm at host:port" is the same contained-chatting-back
antipattern the whole design rejects (§"Why an agent, not ssh"). So the *same
trusted bootstrap that couriers the one-time secret ALSO assigns the child's
port* (`AEO_PORT`), delivered together on the same ride (§"Channel security").
The parent remembers what it assigned.

Concretely, a child's http conduit address is:

- **IP** — `ipam.resolve_ip(system, child)`, the sticky per-node IP the VM driver
  and pf rules already resolve. The node already has an address; recursion reuses
  it, invents nothing.
- **Port** — parent-assigned at bootstrap (not chosen by the child, not a global
  constant every agent shares). One conduit port per agent, minted like the key.

So a parent delegating to `child` dials `http://<resolve_ip(system,child)>:<port
it stamped>/dispatch`. On a single host (the localhost proof) all agents share
`127.0.0.1`, so the parent assigns **sequential ports** (`base + depth`: outer
9451, inner 9452, …) and records each — mirroring exactly what the real courier
does across machines, where the IP disambiguates and the port can be constant.

Rejected alternative: computing `resolve_ip(child):9450` with a fixed shared
port. Fine across machines (one agent per IP) but collides on one host, and —
more importantly — a global well-known port is a standing surface; a
parent-assigned port is one more thing minted-and-couriered, consistent with the
key. The child is *told* where it lives.

## Transport — file (v0) and HTTP (drafted)

The message types are aeo's existing ones (`Boot`/`Probe`/`Halt` + a report
back), so the transport is just a pipe for already-defined `lib/protocol` lines.
Two transports exist behind the same tiny surface (`put`/`recv_one`/dirs), so
`bin/aeo-agent.ae` swaps the module and nothing else changes:

- **`lib/transport_file`** (v0, in use) — a shared rendezvous dir, one command
  per file, maildir-style. Crude, zero-dependency, works container↔host over a
  bind mount. Isolates the protocol + recursion from any network plumbing.
- **`lib/transport_http`** (drafted) — a private HTTP channel on a socket, built
  on **`std.http.server`** (NOT ssh). The agent inside the node is the *server*;
  the parent on the host is the *client*. Modeled on aeb's `aeb-agent` (port
  9440; aeo's is 9450). Endpoints: `/health` (open liveness, no auth — the
  "is the agent resident?" probe), `/ping` (authed identity), `/dispatch`
  (authed; POST one protocol command line, drained by the agent core via the
  same `recv_one()` name).

**ssh is bootstrap-only.** ssh's single job is getting the agent *in* and
*launched* (push the binary, start it, session closes). The standing channel is
then the HTTP socket — parent-as-client → agent-as-server — so aeo holds **no
standing ssh credentials** and there is **no interior ssh path** the workload
shares. `probe_health` after the launching ssh closes is exactly the residence
(TSR) check.

## Channel security — the bank-courier model (NOT PKI)

The right mental model is **1970s inter-bank key exchange**: a key hand-carried
by a trusted courier on a motorbike, not a certificate authority. This is the
thing PKI *replaced* — and for this one channel the old way is strictly better,
because aeo already has a courier.

**ssh is the motorbike.** The bootstrap ssh session is an already-authenticated,
encrypted, trusted ride into the node. So as ssh launches the agent it
**hand-delivers a one-time secret**: the host mints a fresh random key, installs
it as the agent's configured token, and keeps the matching copy. The key never
crosses an untrusted network to get established — it rode in on the ssh courier.
After that ssh leaves; the standing HTTP channel is authed by the couriered key.

This is a **symmetric pre-shared key, not a keypair** — no CA, no certificate, no
issuance, nothing to pin. Two parties, one secret, hand-carried.

> Status (proven-vs-modeled, honest):
> - `bin/aeo-agent.ae` v0 over **`transport_file`** uses a *warn-level* shared
>   token (mismatch logs, still proceeds).
> - **`transport_http`** is drafted and **fail-closed** (401 when the token is
>   absent/wrong; unconfigured token denies). Its auth is already a shared secret
>   (`token_ok` / `set_serve_token`) — the *right shape*. What's missing is below.
>
> Every piece is **stock Aether stdlib — this is wiring, not inventing**:
> mint the key with `std.cryptography.drbg` (CSPRNG); verify constant-time with
> `std.cryptography.hmac` (`hmac_sha256`); run the socket over TLS via
> `std.http.server`'s h2-TLS (see `aether/examples/stdlib/http-server-h2-tls.ae`,
> integration tests `http_server_tls`). NO CA and NO keypair needed — the
> `contrib/cryptography` asymmetric suite (ed25519/p256/rsa/x25519, even ML-KEM)
> is deliberately unused here; symmetric pre-shared key is the whole point.

Two properties make "the agent serves the container, never the workload" real,
plus one gap to close:

1. **No surface to the node's other processes.** The agent must not expose an
   API/port/socket the contained workload can call to reach the parent. It is
   co-resident with the workload but offers it nothing — its only channel is to
   the container, and the workload cannot speak on it. (Partly met today by the
   endpoint split: `/health` open, `/dispatch`+`/ping` authed.)

2. **One-time, ssh-couriered, dies with the agent.** The shared secret must be
   *freshly minted per agent per boot* and delivered by the bootstrap ssh (not a
   static or operator-chosen token), so no key material outlives the agent and
   "single parent" falls out of "one secret, one courier." This is the gap from
   today's code: the `token` cell exists and is checked, but it must become
   ssh-minted-and-delivered + ephemeral. **No CA, no keypair — this is the bank
   courier, done right.**

3. **TLS on the socket (required).** The couriered secret is a *bearer* secret,
   so the HTTP channel MUST run over TLS — otherwise the secret is observable /
   replayable on the wire. TLS here is for *confidentiality of the channel*, not
   identity (identity is the couriered key); a self-signed/ephemeral server cert
   is fine — again, no CA. This is remaining work alongside (2).

## What this changes

- The README "frontier" line moves from *"needs over-ssh dispatch"* to
  *"needs aeo-agent"* — and it's a better story (containment-respecting,
  depth-agnostic, protocol-uniform).
- It's the build that earns the **nesting row** in the Principles-of-
  Containment scorecard: today the nested tree is *declared + gated*; with
  aeo-agent it *executes*, recursing to arbitrary depth without any node
  knowing how deep it is.

## Build order — DONE (what shipped, in order)

1. [x] `aeo-agent` as a tiny binary speaking the runner's message types over the
   simplest transport (shared file), then a port (`transport_http`).
2. [x] Runner dispatch: `get_host(nm) != ""` nodes route to the guest's agent
   (`driver_vm.agent_delegate`) instead of the ssh-into-guest driver — opt-in
   via `AEO_AGENT_PATH=1`.
3. [x] Bake the agent into a guest via a cloud-init courier seed
   (`build_agent_seed`) — `_up_kvm` builds it, launches the guest persistently
   (systemd-run), the agent auto-starts; one-level nest converges end-to-end.
4. [x] Recurse: the resident agent brings up its child (async `delegate` → fires
   the child container-agent in the background → `status` poll), proving two
   levels = N. Full chain live on real KVM (`aeo up examples/agent_nested_min.ae`).
5. [x] Self-attestation (`attest` verb) — the resident agent re-verifies its
   confinement from inside (deny_egress drift), the containment payoff of §5.4.

Remaining (see the honest proven-vs-modeled note at the top): TLS on the wire;
drop `AEO_BOOT_NOOP` for a real workload in the child; make the agent path the
default; deeper substrate coverage (jail/bhyve arms of the agent path).
