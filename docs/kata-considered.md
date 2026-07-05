# Kata Containers in aeo — a microVM-tier KIND (built), not a podman engine

**STATUS: BUILT + live-proven 2026-07-05.** A first-class `kata("name"){}` kind (option
1 below), driven through containerd's shim-v2 via nerdctl (`lib/driver_kata`), wired
into compose/runner/supervisor/conformance. LIVE-PROVEN on CachyOS: `aeo up` a `kata()`
node boots a real microVM whose **guest kernel (6.18.35) DIFFERS from the host
(7.1.2-cachyos)** — genuine VM isolation, not a shared-kernel container; the supervisor
adopts + releases it; `/status` reports it alive. specs: spec_driver_kata.ae (5) +
conformance. The first take (an `engine("kata")` podman flag) was WRONG, proven wrong
live, and reverted — the history below is kept because the reasoning is what led to the
right design.

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

## What was built (option 1)

`lib/driver_kata` + the `kata("name"){}` kind. It shells **`nerdctl run -d --runtime
io.containerd.kata.v2 --name NAME IMAGE`** (self-sudo; the same NOPASSWD contract as
driver_lxc/nspawn) — the SUPPORTED containerd shim-v2 seam, NOT podman `--runtime`
(which fails, `Invalid command "create"`). `up`/`down`(`nerdctl rm -f`)/`probe`(`nerdctl
ps`) mirror the other name-registry drivers; the supervisor routes `kata` in
`_driver_down`/`_driver_probe` exactly as it routes firecracker/kvm. `available()` gates
on nerdctl presence; `up` verifies the microVM reached running (a bad shim / no
/dev/kvm fails loud).

Host prereqs (proven on CachyOS): `containerd` + `nerdctl` installed and containerd
running; the Kata static release at `/opt/kata` with `containerd-shim-kata-v2` on
containerd's PATH (symlink to `/usr/local/bin`); `/dev/kvm`. `image()` is an OCI image;
`command()` the payload. GOTCHA: `--runtime` is a `run` SUBCOMMAND flag — it must come
AFTER `run` (nerdctl rejects it before the subcommand: "unknown flag: --runtime").

## The still-valid alternative (option 2)

Kata ≈ "a `container` nested in a microVM", which aeo ALSO expresses explicitly:
`firecracker("vm"){ container("app") }`. The `kata` kind is the pre-packaged, one-verb
form (VM isolation + container API in a single node); the nesting grammar is the
assemble-it-yourself, boundary-visible form. Both are legitimate; a composition picks
whichever reads better. See `docs/aeo-agent.md` for the nesting/recursion model.
