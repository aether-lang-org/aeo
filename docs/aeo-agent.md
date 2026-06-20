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

- **The contained reaches OUT, the container receives.** On boot the agent
  dials the parent ("I'm `app`, I'm up, here's my health") — the contained
  *reports*; the parent *listens*. The contained "only suspects it is
  contained" (the post's phrase) and reaches back *only where configured* —
  the agent's one endpoint.
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

## Transport options (rendezvous)

The agent dials out; the parent listens. Candidates, cheapest first:

- a **port** the parent opens and the agent connects to (works across the VM
  NIC; the same `ip()`/network the data plane uses);
- **std.ipc** / a forwarded fd for the container-in-host case (no network);
- a **shared file / dir** the parent polls and the agent writes (crude but
  zero-dependency; fine for v0 liveness reporting).

The message types are aeo's existing ones (`Boot`/`Probe`/`Halt` + a report
back), so the transport is just a pipe for already-defined messages.

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
