# Getting aeo running on a fresh CachyOS / Arch box — failure modes (hardening)

Captured 2026-07-04 standing up a fresh **CachyOS** box (Arch-based, **gcc 16.1.1**,
podman 6.0.0) as an aeo host. Every stumble below is a getting-started gap worth
fixing upstream (aether) or documenting. The box is Intel Alder Lake-N (UHD gfx),
cgroups **v2**, fish as the default login shell.

## The failure chain (in order hit)

### FM1 — `make install` (the `release` target) fails under gcc 16 `-Werror`
The `release` target compiles with `-O3 -flto -Werror`. gcc 16.1.1 promotes
`-Wdiscarded-qualifiers` to an error where older gcc only warned:
```
lsp/aether_lsp.c:16:19: error: initialization discards 'const' qualifier ...
    char* start = strstr(json, search);            // strstr(const char*, ...) -> char*
std/net/aether_http_server.c:1293:22: error: ... discards 'const' qualifier ...
    char* line_end = strstr(raw_request, "\r\n");
std/net/aether_http_server.c:1363:18: error: assignment discards 'const' qualifier ...
```
**Upstream fix (aether):** declare those `strstr` results `const char*` (or cast),
in `lsp/aether_lsp.c` and `std/net/aether_http_server.c`. Three sites. Real
portability bug — current gcc on Arch/Fedora-rawhide will hit it. Until fixed,
`make` (debug, no `-Werror`) works; `make install`/`release` does not.

### FM2 — `ae build` can't find the compiler → "Aether compiler not found"
After a plain `make`, `ae build file.ae` prints *"Aether compiler not found. Run
'make compiler' or set $AETHER_HOME."* The `ae` front-door expects an INSTALL
layout (`$PREFIX/bin/aetherc`, `$PREFIX/share/aether/{std,runtime}`,
`$PREFIX/lib/aether/*.a`), not the raw `build/` tree.
**Workaround:** either `make install PREFIX=$HOME/.local` (blocked by FM1) or
hand-stage the layout (see the working recipe below).

### FM3 — `make install` runs `release: clean` and WIPES the working build
`install: release`, and `release: clean`. So a user who runs `make` (works) then
`make install` (fails at FM1) is left with **`build/` deleted** AND a partial
`~/.local` — strictly worse than before they tried to install. The half-installed
`~/.local/bin/{ae,aetherc}` linger and mislead.
**Upstream fix:** don't `clean` inside `release` (or make `install` depend on a
non-destructive build); at minimum, fail `install` BEFORE cleaning.

### FM4 — link error: `undefined reference to aether_caps_malloc/aether_caps_free`
Hand-staging `libaether.a` from a **stale** copy (e.g. one left by a prior partial
build) links against a `.a` missing the resource-caps runtime
(`runtime/aether_resource_caps.c`, `runtime/memory/aether_{arena,pool}.c`).
**Cause:** staged a stale `libaether.a`, not the freshly-`make`d one.
**Fix:** always stage the `libaether.a`/`libaether_compiler.a` from the SAME `make`
run as the stdlib, and re-stage after every rebuild.

### FM5 — default shell is `fish`, breaks `bash -style` command chaining
CachyOS ships **fish** as the login shell. `cmd1; cmd2` and `(...)` in echoes
mis-parse over ssh. Not aeo's bug, but a real "drive it over ssh" trap.
**Workaround:** `ssh host 'bash -lc "..."'` or `chsh -s /bin/bash` (bash IS
installed; `/bin/sh -> bash`).

## The WORKING recipe (fresh CachyOS → building aeo), for the docs

```sh
# 0. prereqs (present on CachyOS: gcc make; else: sudo pacman -S --needed base-devel)
# 1. build the toolchain — PLAIN make (NOT make install; FM1)
cd aether && make -j4                       # -> build/{ae,aetherc,libaether.a,libaether_compiler.a}
install -Dm755 build/ae build/aetherc -t ~/.local/bin/

# 2. hand-stage the layout ae expects (until FM1/FM3 are fixed so `make install` works)
mkdir -p ~/.local/{share/aether,lib/aether,include/aether}
cp -r std runtime ~/.local/share/aether/                       # stdlib + runtime SOURCES
cp build/libaether.a build/libaether_compiler.a ~/.local/lib/aether/   # FRESH .a (FM4)
cp -r include/* ~/.local/include/aether/ 2>/dev/null || true

# 3. build aeo
export PATH=$HOME/.local/bin:$PATH AETHER_HOME=$HOME/.local
cd aeo && ae build bin/aeo.ae -o /tmp/aeo --lib lib            # -> Built: /tmp/aeo
```

## What worked out of the box (podman 6 baseline, for the live tests)

- podman **6.0.0** rootless: `podman run --rm alpine echo` pulled + ran.
- cgroups **v2**: `--memory 128m` → container `memory.max` = 134217728 (the
  `limit{}` confinement path works on the podman-6/v2 substrate).
- net backend: **netavark** (podman 6's nftables path); `passt` (pasta) pulled in
  as a podman dep — the pasta-forwarder work is testable here.
- `podman run --help` has `--gpus`; `/dev/dri/renderD128` present (Intel iGPU) —
  the `gpu()` DRI path is testable (AMD `--gpus` needs an AMD box).
