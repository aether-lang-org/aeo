# Kata Containers in aeo — a peer VM-runtime, NOT a podman engine

Written 2026-07-05 after a false start. First take framed Kata as an `engine("kata")`
value on `container()` (a podman `--runtime` flag). That was **wrong**, proven wrong
live, and reverted. This note records the corrected understanding so it isn't
re-attempted from the wrong premise.

## What Kata actually is

[Kata Containers](https://katacontainers.io/) runs each container **inside a
lightweight microVM** — its own guest kernel + a bundled hypervisor (QEMU, or
firecracker, or Cloud Hypervisor) — giving VM-grade isolation with the container
image/API. It is a **standalone runtime** with its own toolchain: `kata-runtime`,
`containerd-shim-kata-v2`, `kata-monitor`, and its own bundled `qemu-system-*` /
`firecracker` / `jailer` (all under `/opt/kata/bin` in the 3.x static release).

The key realization (and the operator's correction that fixed the design): **Kata is
more like LXC or firecracker than like docker** — a substrate/runtime in its own
right, *outside* the podman/docker world, that other tools may *drive* but that does
not belong *to* them.

## Why the `engine("kata")` framing was wrong

`engine()` on `container()` selects a **container ENGINE** (podman/docker/wslc) — a CLI
that speaks the `run -d --name … IMAGE` verb set, resolved by `os_which(engine)`. The
first take treated Kata as "podman + `--runtime kata`". But:

- **It doesn't work.** Live on CachyOS (Kata 3.32, podman 6.0.0, kata registered as a
  podman runtime): `podman run --runtime kata alpine` → `OCI runtime error: kata:
  Invalid command "create"`. Kata 3.x's `kata-runtime` is NOT a runc-CLI drop-in (no
  bare `create`/`start`/`delete`); it targets **containerd's shim-v2**
  (`containerd-shim-kata-v2`), not podman's `--runtime` OCI-CLI. Podman↔Kata wiring is
  a known-fiddly, less-trodden path — a Kata-integration concern, not an aeo one.
- **It misrepresents Kata.** An `engine("kata")` implies "a container engine flavour."
  Kata is a *VM-isolation runtime* — categorically the microVM tier, not the container
  tier. The failure above is the evidence: Kata is a peer of podman, not a plugin of it.

## The correct model (if/when built)

Kata belongs with aeo's **microVM tier**, next to `firecracker`/`kvm`, NOT as a
container engine. Two honest shapes:

1. **A `kata("name"){}` kind + `driver_kata`** — mirroring how `lxc` and `firecracker`
   are their own kinds with their own drivers. It drives Kata's native path
   (`containerd-shim-kata-v2` via a containerd/nerdctl seam, or `kata-runtime` in its
   supported mode), holds the sandbox by pid/shim like the other VM tiers, and the
   supervisor routes `kata` in `_driver_down`/`_driver_probe` exactly as it now routes
   `firecracker`/`kvm`.

2. **Recognize Kata as aeo's OWN nesting primitive, pre-packaged.** Kata ≈ "a
   `container` nested in a microVM" — which aeo ALREADY expresses:
   `firecracker("vm"){ container("app") }` (or the bhyve/kvm nest). aeo builds the
   VM-isolated-container from parts it already has; Kata ships it as one opaque unit.
   From this lens, aeo may not need a `kata` kind at all — it has the capability, just
   assembled explicitly (and visibly in the composition) rather than hidden behind a
   runtime. aeo's "the boundary is explicit in the config" philosophy prefers the
   visible form.

## Recommendation

Do NOT add `engine("kata")`. If a first-class Kata tier is ever wanted, it's option 1
(a `kata` kind + driver, microVM-tier), and the live-proof needs Kata driven through
its *supported* seam (containerd shim-v2), not podman `--runtime`. Until then, aeo
already offers the same isolation via its explicit nesting grammar (option 2). The
installed Kata 3.32 on the CachyOS box (`/opt/kata`) remains available if that tier is
built. See `docs/aeo-agent.md` for the nesting/recursion model that option 2 leans on.
