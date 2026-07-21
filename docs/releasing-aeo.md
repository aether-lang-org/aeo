# Releasing aeo-agent

Canonical, human- and LLM-readable guide to cutting an `aeo-agent` release. The
authoritative source is `.github/workflows/release-aeo-agent.yml`; this doc
explains it and is the thing to read first. If the two ever disagree, the
workflow wins — fix this doc to match.

## What gets released

`aeo-agent` — the lean, in-guest orchestration agent a guest **fetches** (via
cloud-init, or an ssh push) to complete its node and run its workload. It is NOT
the `aeo` CLI; it is a separate, dedicated binary with its own version line
(`aeo-agent-v*`), decoupled from any `aeo` versioning.

Each release is an **immutable, versioned** GitHub Release: one tag → one set of
assets → their SHA256s, retained forever (so a pinned SHA in a cloud-init
snippet never breaks, and you can roll back / bisect).

### Assets (as of this writing)

| asset | guest it serves | linkage |
|---|---|---|
| `aeo-agent-linux-x86_64-static` | any Linux — full OS, debian-slim, Alpine/musl, busybox | **STATIC** (no runtime `.so` deps) |
| `aeo-agent-windows-x86_64.exe` | Windows (Win11 bhyve guests; workload via WSL2+podman) | dynamic vs Windows system DLLs (always present) |
| `aeo-agent-freebsd-x86_64` | FreeBSD (bhyve guests) | dynamic vs the base `libc.so.7` + `libthr.so.3` (always present in a FreeBSD userland) |

Each asset ships a companion `<asset>.sha256`. The run summary prints a table of
all asset SHA256s to pin.

> Historical note: pre-`v0.1.2` the linux asset was named
> `aeo-agent-linux-x86_64-glibc` (dynamic). It is now `…-static`. Some older
> docs/scripts may still reference the glibc name — treat `…-static` as current.

## How to cut a release

**A release is triggered by pushing a tag matching `aeo-agent-v*`.**

```
git tag aeo-agent-v0.1.3
git push origin aeo-agent-v0.1.3
```

That runs the workflow and — because it's a real tag — **publishes** a GitHub
Release with the assets attached. The latest tag is `aeo-agent-v0.1.2`, so the
next is `v0.1.3` (bump per your change).

### Dry run first (no publish)

`workflow_dispatch` builds + checksums but does **NOT** tag or publish — use it
to test the pipeline before committing to a version:

```
gh workflow run release-aeo-agent.yml                 # latest aether toolchain
gh workflow run release-aeo-agent.yml -f ref=<sha>    # pin a specific aether ref
```

or the "Run workflow" button on the Actions tab. Only a pushed `aeo-agent-v*`
tag creates an actual Release — there is never a rolling/overwritten asset.

## How the CI builds it (mechanics)

Three build jobs — `build-linux`, `build-windows`, `build-freebsd` — feed a
`release` job that publishes whatever artifacts they produced.

### The runner has no prebuilt `ae` — it builds the toolchain from source

There is no downloaded `ae` binary. The "Install the Aether toolchain" step runs
`get.sh`, which fetches a pinned Aether **source tarball** and `make install`s
it. This has no chicken-and-egg because **Aether compiles to C** — the only
prerequisites are a C compiler + GNU make (hence the `build-essential` apt line).
Chain: `get.sh` → Aether source → C → `make` → `ae` on `PATH`.

The `ref` input (or the latest Aether tag by default) pins **which** Aether
version is built. That is the same version the FreeBSD gate checks (below).

### `build-linux` — native, static

Native x86_64 build with `AE_CC="gcc -static"`. The job **asserts** the result
is an x86_64 ELF *and* statically linked — if not, it fails the build, because
the asset name would be a lie and a dynamic binary hits the exit-127 trap in
slim/busybox guests. This is the load-bearing asset.

### `build-freebsd` — cross-compiled, self-gating

Cross-compiles on the Linux runner via `ae build --target=x86_64-freebsd` (zig
under the hood). It fetches a FreeBSD base sysroot + third-party deps from
[aether-crossbuild](https://github.com/aether-lang-org/aether-crossbuild)
(`fetch-freebsd-base.sh` + `provision.sh`; nghttp2 is intentionally omitted —
the plaintext agent doesn't need HTTP/2 and it doesn't cross-build for FreeBSD).

**The gate:** this job only produces its asset when the built `ae` is
`>= AEO_FREEBSD_MIN_AE` (currently `0.428.0`) — the first Aether version carrying
the FreeBSD-cross **pthread fix** (link `libthr.so.3` by path; `-lpthread`
doesn't resolve under zig-lld + `-nostdlib` against the split base). Below that
version the job **skips cleanly**: a tag still ships the linux asset, and the
FreeBSD asset appears on a later tag once that `ae` is released.

> If you cut a tag and the FreeBSD asset is missing, check the `build-freebsd`
> "Gate" step — the toolchain is probably older than `AEO_FREEBSD_MIN_AE`. To
> test FreeBSD before that release, do a `workflow_dispatch` dry run with
> `-f ref=<aether-branch-or-sha carrying the fix>`.

## Consuming a release (guest side)

A guest fetches the asset for its OS/arch, **verifies the pinned SHA256**
(fail-closed), then runs it. Linux example:

```
curl -fsSL https://github.com/aether-lang-org/aeo/releases/download/aeo-agent-v0.1.3/aeo-agent-linux-x86_64-static -o /usr/local/bin/aeo-agent
echo "<SHA256-from-the-release>  /usr/local/bin/aeo-agent" | sha256sum -c -
chmod +x /usr/local/bin/aeo-agent
```

Real consumers of this pattern:
- `examples/checks/proxmox_cloudinit.yaml` — the cicustom snippet that curls +
  SHA-verifies the agent into a proxmox_vm guest.
- `examples/checks/proxmox_host_agent_install.sh` — host-side installer.
- `docs/aeo-and-proxmox.md` — the proxmox delivery narrative.

When you bump the release, update the pinned `aeo-agent-v*` version **and** the
SHA256 in those consumers (the run summary prints the SHA to copy).

## Adding a new asset permutation (arch/OS)

The agent's targets are dictated by **where guests actually land**, not by what
`ae` can cross-compile. Add an asset only for a (guest OS, arch) that aeo
provisions *and* that the agent can function on, and keep the name honest with a
`file`-based assert (as every build job does).

- **aarch64-linux** — wanted (ARM VMs / Pi / Graviton), but `ae --target` has no
  musl triple, so a static aarch64 asset isn't reachable by cross-compile today.
  Tracked in `asks/aarch64-agent-runproof-and-static.md` (native ARM build +
  run-proof needed before wiring a job).
- **x86_64-macos** — the agent cross-builds and even runs + serves /health on
  macOS, but aeo has NO macOS-guest substrate (no mac driver; nothing provisions
  a macOS VM as a workload target). A fetchable agent for a guest type that
  doesn't exist would be dead weight. Revisit only if a macOS substrate appears.
- **windows-x86_64** — SHIPPED. The agent imports `driver_windows` and
  platform()-dispatches the workload to WSL2+podman. Note the workload path
  needs WSL2+podman IN the guest; the agent CORE (boot/contain/protocol/health)
  runs regardless, which is the same bar the FreeBSD asset ships at.
