# aeo-agent — orchestration that recurses through the containment tree

Status: **design note**, not yet built. Captures the model for the nested /
substrate-crossing tier (a container inside a VM inside a host), which the
flat driver model can't reach. This supersedes the earlier "step into the
guest over ssh" framing — that was the wrong directionality.

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

## Build order, when we get to it

1. `aeo-agent` as a tiny binary speaking the runner's message types over the
   simplest transport (shared file or a port).
2. Runner dispatch: route `get_host(nm) != ""` nodes to the host's agent
   instead of a local driver.
3. Bake the agent into a guest via `dockerfile()` (container) and a jail
   root, and prove a one-level nest end-to-end (container inside a VM,
   brought up by the agent, reporting back).
4. Recurse: an agent that itself hands instructions to a deeper child — prove
   two levels, which by construction proves N.
