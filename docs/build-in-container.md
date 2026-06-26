# Building aeo on an immutable host (Bazzite) via build-in-container

aeo (and aeo-agent) build with Aether's `ae`/`aetherc` + gcc. An **immutable
host** — Bazzite / Silverblue / Fedora-atomic — won't let you install those. The
fix is the same one aeb uses (`../aeb/tools/container`): build *inside a
container* that has the toolchain, with the sources bind-mounted out.

aeo is SIMPLER than aeb here: aeo only needs **`ae`** (it doesn't build with aeb),
so the upstream **`aether-builder`** base — or any **aeb-toolchain** image that
layers on it — already has everything. No aeo-specific toolchain image needed.

## Verified on Bazzite (2026-06-26)

Box: `bazzite@192.168.0.57` (the same physical machine dual-booted from GhostBSD;
clear the stale GhostBSD host key with `ssh-keygen -R 192.168.0.57` first). It had
`localhost/aeb-toolchain:fresh` (372 MB, `ae 0.257.0`) from prior aeb work.

- `tools/build-in-container.sh` → built **aeo** (111K) + **aeo-agent** (121K),
  Linux x86-64, correctly user-owned. Both RUN natively on the host (`aeo` prints
  usage; `aeo-agent` prints its bootstrap msg). aeo built clean even under the
  old ae 0.257 — the front-door uses no syntax newer than that.
- `AEO_CHECK=examples/silly_addition_kvm.ae sh tools/build-in-container.sh` →
  `ae run` the demo's CHECK mode IN the container: 3/3 passing. Self-contained
  (no host `ae`, no front-door).

## The runtime-`ae` caveat for `aeo up` (DEPLOY) on an immutable host

The aeo front-door (`bin/aeo.ae`) **builds the composition at runtime**: `aeo up
<compose.ae>` stages the compose as the `aeo_compose` module, copies `lib/`, and
shells `ae build run.ae` to produce the deploy binary. So the `aeo` binary needs
**`ae` on PATH when it runs** — which an immutable host lacks (ae is only in the
container).

Two ways forward (same shape as aeb's immutable-host story):
1. **Run `aeo` itself inside the container** (where `ae` lives), bind-mounting the
   compose + the podman socket for container-kind deploys. This is the immutable-
   host deploy path.
2. **Install `ae` on the host** (not possible on a truly immutable box).

The demo CHECK path sidesteps this entirely (`ae run <demo>` is one self-contained
step in the container). Full `aeo up` deploy on Bazzite is the next step —
run aeo-in-container, or precompile the composition.

## Bazzite/SELinux traps (from ../aether/ctr_notes.md)

- bind mounts need **`:Z`** (relabel for the container)
- the work dir must **NOT** be `$HOME` (relabeling $HOME is refused — use a
  dedicated dir like `~/aeo-build`)
- do **NOT** pass `--userns=keep-id` (crashes this crun; output is user-owned
  without it)
