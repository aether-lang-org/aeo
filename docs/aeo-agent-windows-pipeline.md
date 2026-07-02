# aeo-agent on Windows — the build/store/deploy pipeline (plan)

The 3-machine pipeline Paul proposed for getting the Aether `aeo-agent` running
inside a Win11 bhyve guest. Captured now; actionable once the Win11 guest exists
(see `windows-guest.md`). The agent STAYS Aether (Aether targets Windows via
mingw — see the correction in windows-guest.md); this is about *producing* and
*delivering* the Windows binary.

## The pipeline (Paul's shape — it's right)

```
 Bazzite boot (Linux)          Chromebook (this repo)        GhostBSD Win11 guest
 ─────────────────────         ──────────────────────        ────────────────────
 cross-build aeo-agent.exe  →  store the .exe (artifact)  →  scp in over sshd Paul
 (Aether→C→mingw-w64-gcc)      (durable, version-pinned)      enabled at first boot,
                                                              start it (scheduled
                                                              task / service = TSR)
```

- **Bazzite is the build host** because a Windows cross-toolchain
  (`mingw-w64-gcc`) is trivial on Linux and painful on FreeBSD. The same physical
  box dual-boots Bazzite ↔ GhostBSD.
- **Chromebook stores the artifact** — durable across reboots of the box, and
  the natural place to keep a version-pinned `aeo-agent-<ver>-x86_64.exe`.
- **GhostBSD delivers** — the driver scp's the .exe into the guest over the
  OpenSSH that Paul enables at first boot (the bootstrap channel), then starts it
  for TSR (Windows scheduled task / service — the Windows arm of the init-aware
  push, cf. memory `aeo-agent-tsr-init-systems`).

## BLOCKERS — status (2026-07-01: #2 CLEARED, #3 substantially de-risked)

1. **Agent body is Linux-bound, not the language.** `bin/aeo-agent.ae` shells to
   podman (`driver_linux` + `_ensure_child_container`'s `podman run`). mingw can't
   compile podman calls into a Windows .exe. Needs a `driver_windows` (or
   `select(linux:…, windows:…)`) arm that runs the workload natively (winget/wslc
   — see the `driver_wslc` TODO — launch the child, probe via tasklist/HTTP).
   → STILL OPEN. The one real remaining blocker for a *functional* Windows agent.
   (The agent's CORE — protocol, transport_http, agent_auth, self-attest — is
   substrate-agnostic and already cross-compiles; only the child-bring-up body is
   Linux-bound.)

2. ~~**Agent isn't on the conduit yet.**~~ **CLEARED.** The agent is fully on
   `lib/transport_http` now (HTTP conduit live-proven: recursion, async delegate,
   `status`/`attest`, bank-courier auth — the whole real-KVM nested `aeo up`). A
   Windows .exe of the agent can speak the conduit as-is.

3. **mingw cross-build pipeline — SUBSTANTIALLY DE-RISKED (spike run 2026-07-01).**
   Was "reasoned, not run." Now run, on Bazzite (mingw in a debian container — the
   immutable-host path):
   - `gcc-mingw-w64-x86-64` cross-compiles a trivial C program to a valid Windows
     `.exe` (PE32+, `MZ` magic). ✅
   - Aether's runtime is genuinely Windows-portable: three IO pollers
     (`aether_io_poller_epoll`/`kqueue`/**`poll`**), `_WIN32` guards throughout.
     `std/net/aether_net.c` — the **Winsock socket layer the agent depends on** —
     cross-compiles clean (EXIT=0). ✅
   - Full sweep of runtime + std/net/crypto/os/string: **53 ok, 9 failed** — and
     every failure is either not-runtime (`*_example.c`/`*_bench.c`), a Linux-only
     file Windows wouldn't build (`libaether_sandbox_preload.c` = an LD_PRELOAD
     shim), or a wrong-`-I`-path artifact of the naive sweep on the *other* poller
     family (the Makefile selects the right poller per platform via `IO_POLLER_SRC`;
     the portable `poll` one already built). So no portability WALL — the
     Windows-relevant runtime cross-compiles.
   #3 RESOLVED & VERIFIED (2026-07-02): built ON WINDOWS, not cross-from-Linux.
   The cross-from-Linux path fights the Makefile (it detects Windows via `uname`,
   so it wanted the Linux poller + no `-lws2_32`). The clean answer (Paul's): build
   in **MSYS2 on the Win11 guest itself**, where `uname` = `MINGW64_NT-...` and the
   Makefile's native-Windows branch just works. MSYS2 was already at `C:\msys64`
   (gcc 16.1.0, make). After two build-system false starts (an incomplete tarball;
   a wrong `libaether.a` target name — it's `stdlib`), a `make` with the full source
   tree (`lsp tools VERSION` included) produced, in `~/aether/build/` on the guest:
     libaether.a          595202 B   ← the pending piece, DONE
     libaether_compiler.a 668912 B
     aetherc.exe         8483084 B   ← PE32+ x86-64, `Aether Compiler v0.343.0`
     ae.exe               462152 B   ← PE32+ x86-64, `ae 0.343.0 windows-x86_64`

   FULL NATIVE CHAIN PROVEN END-TO-END on the guest (all stages ran there):
     aetherc.exe  hello.ae → hello.c       (8358 B of C, type-checked)
     gcc          hello.c + libaether.a → hello2.exe   (rc=0; -lws2_32 -lcrypt32 -lbcrypt)
     file         hello2.exe → PE32+ executable for MS Windows, x86-64
     RUN          → "hello from native windows aether"
   So the guest compiles ANY Aether program → C → native `.exe` on its own. RUN was
   already proven earlier (the cross-built `hw.exe` prints "hello from a cross-built
   exe"); now the native TOOLCHAIN build is proven too.
   VERIFY METHOD (why the record briefly wobbled): the async-task *summary* lines
   lagged the real guest state — an intermediate `make` FAILED, a later one SUCCEEDED.
   Ground truth is the live guest (`ssh -i win11_key paul@192.168.122.179`, then
   `C:\msys64\usr\bin\bash -l`), not the task-output files. Always re-check the box.

   What's left for a REAL agent .exe is blocker #1 (the Windows agent body —
   driver_windows/wslc, whose substrate we proved: WSL2 + podman live in the guest).

## Suggested order when resumed

1. **Win11 guest exists + snapshotted** (the attended first-boot, sshd enabled).
2. **mingw spike on Bazzite**: cross-build a minimal Aether program (hello +
   a TCP listener) → .exe → scp into the guest over sshd → confirm it runs +
   listens. Proves the whole build/store/deploy chain end-to-end, cheaply.
3. **Agent slice 2**: rewrite aeo-agent onto transport_http (Linux first; verify
   the conduit round-trips against a real listener).
4. **Agent slice 3 (Windows arm)**: `driver_windows`/`select()` body — native
   workload launch; no podman.
5. **Cross-build the real agent** through the now-proven pipeline; store the .exe
   on the Chromebook.
6. **Driver push**: GhostBSD driver scp's the .exe in + starts it as a scheduled
   task; health-poll `GET /health` for residence (the OS-independent TSR check).

## Notes

- The .exe is x86-64 (the box is AMD Ryzen; the Win guest is x86-64). No arch
  cross-concern, only OS.
- Version-pin the stored artifact + record the aeo commit it was built from, so a
  guest's resident agent is traceable to source.
- This same shape generalizes: Bazzite-container cross-build for the LINUX agent
  too (the earlier plan) — Bazzite becomes the build host for both targets.
