# ask (for Nic): aarch64-linux aeo-agent — run-proof + settle the static story

You have an M1 Mac (aarch64) and can spin up Linux VMs, which makes you the
right person to close the one gap I can't from an x86_64 Chromebook: **running**
an aarch64-linux `aeo-agent` and deciding how it should be built for release.

## Context

We just added FreeBSD to the aeo-agent release matrix (proven end-to-end). ARM
is the other obvious permutation — ARM VMs / Pi / Graviton guests are real, and
the release workflow's own comment already flags `aeo-agent-linux-aarch64-*` as
a wanted follow-up. I got aarch64 to **build** but hit two things I can't
resolve here:

| target | builds? | run-tested? | static? |
|---|---|---|---|
| aarch64-linux | ✅ (cross, from x86_64 via zig) | ❌ **no arm box here** | ❌ dynamic glibc only |

The blocker on "static" is specific: `ae --target` accepts only the bare
`aarch64-linux` triple (glibc, → a dynamically-linked ELF needing
`/lib/ld-linux-aarch64.so.1`). It has **no musl triple** (`aarch64-linux-musl`
is rejected), so we can't produce a static aarch64 agent the way the x86_64
release does (`gcc -static`). A dynamic-glibc asset would break the release's
static guarantee — it can't run in Alpine/busybox guests, the exact exit-127
trap the x86_64 static build exists to avoid.

## What I'd like you to do (on your `aeo` checkout)

### 1. Native-static build on your M1, in a Linux ARM VM

The cleanest aarch64 asset is a NATIVE static build — same recipe as x86_64,
just on ARM hardware, which your M1 gives you via a Linux VM (UTM/Lima/Colima →
aarch64 Ubuntu or Alpine). In that VM:

```
# deps for the static link (Debian/Ubuntu):
sudo apt-get install -y build-essential curl tar libssl-dev libnghttp2-dev
# or on Alpine (musl — gives a truly portable static agent):
#   apk add build-base curl tar openssl-dev nghttp2-dev

# install the ae toolchain
curl -sSL https://raw.githubusercontent.com/aether-lang-org/aether/main/get.sh \
  | PREFIX="$HOME/.local" sh
export PATH="$HOME/.local/bin:$PATH"

# build the agent STATIC (mirrors release-aeo-agent.yml's x86_64 job)
AE_CC="gcc -static" ae build bin/aeo-agent.ae -o aeo-agent-linux-aarch64-static --lib lib
file aeo-agent-linux-aarch64-static     # want: ELF aarch64, statically linked
```

If the Alpine/musl path works, that's the ideal — a static musl aarch64 agent
runs in ANY aarch64 Linux guest (full OS, slim, Alpine, busybox), matching the
x86_64 asset's portability.

### 2. Run-proof it

Prove it actually runs and serves — the thing I can't do without ARM hardware:

```
AEO_NODE=armtest AEO_TOKEN=tok AEO_TRANSPORT=http AEO_PORT=19450 AEO_BIND=127.0.0.1 \
  ./aeo-agent-linux-aarch64-static &
sleep 2
curl -fsS http://127.0.0.1:19450/health    # want: ok
```

(That `/health` → `ok` is exactly how I proved the FreeBSD agent on a real box.)
Bonus: run it inside an aarch64 `busybox` or `alpine` container to confirm the
"static → runs anywhere" claim, like the x86_64 asset does.

### 3. Report back which of these is true

- **(a)** native static musl works → we add an `aarch64` native job to
  `release-aeo-agent.yml` on a `ubuntu-24.04-arm` runner (GitHub has ARM
  runners now), mirroring the x86_64 static job. Cleanest outcome.
- **(b)** only glibc-static or glibc-dynamic works → tell us the constraint;
  we decide whether a glibc-only aarch64 asset is worth shipping (probably yes
  for full-OS ARM guests, with the portability caveat documented).
- **(c)** something breaks in the agent on ARM (a real portability bug in
  `bin/aeo-agent.ae` / a driver / std) → capture it; that's a genuine find.

## What you do NOT need to do

- No cross-compile setup — build NATIVELY on ARM (your M1 VM). The x86_64→arm
  cross path here has the no-musl-triple limitation; a native build sidesteps it
  entirely and is the more trustworthy asset anyway.
- No release/tag — just build, run-proof, and report. Wiring the workflow is
  ours once you confirm which linkage actually runs.

## Reference

- Release workflow (the x86_64 static job to mirror):
  `.github/workflows/release-aeo-agent.yml`
- The FreeBSD job we just added is the template for "a second-arch/OS agent
  asset" if we go the CI route instead of a native ARM runner.
