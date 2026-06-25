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

## BLOCKERS — must be done before the pipeline can produce a working .exe

These are why we can't just cross-build today:

1. **Agent body is Linux-bound, not the language.** `bin/aeo-agent.ae`
   `import driver_linux` and calls podman (`driver_linux.up/down/probe`). mingw
   cannot compile podman calls into a Windows .exe. Needs a `driver_windows` (or
   `select(linux:…, windows:…)`) arm that runs the workload natively on Windows
   (winget-install Python, launch `python app.py`, probe via tasklist/HTTP).
   → This is agent **slice 3**-ish work; a hard prerequisite to the cross-build.

2. **Agent isn't on the conduit yet (slice 2).** Still on the old shared-dir
   `transport_file`; must be rewritten onto `lib/transport_http` (built, tested)
   so a Windows agent can actually be driven. A .exe that can't speak the conduit
   is useless.

3. **mingw cross-build pipeline UNPROVEN.** Aether *targets* Windows (docs prove
   it), but "aetherc → C → mingw-w64-gcc → .exe that runs + opens a socket" is
   reasoned, not run. Likely needs Windows wiring: `-lws2_32` for sockets, the
   std.http server on Winsock, path/`select()` handling. A cheap spike (cross-
   build a minimal socket program, run it on the Win guest) would de-risk this
   BEFORE investing in the real agent.

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
