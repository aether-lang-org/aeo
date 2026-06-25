# aeo TODO

Open work, honest about what's built vs. proven-live. The containment roadmap is
the live focus (GhostBSD box `paul@192.168.0.57`); see also
`docs/pf-enforcement-next-steps.md` and `docs/bsd-host-setup.md`.

## Containment / impregnability roadmap

The question driving this: *orchestrated trees of compute nodes that contain
malware and are impregnable to attack.* Two axes — stop a node REACHING things
(constrain) and stop it STARVING the host (limit) — plus supply-chain + forensics.

| Axis | Built | Live-proven | Notes |
|---|---|---|---|
| **jail nodes (driver_bsd)** | ✅ | ✅ **real jail boots+probes+contains, live** | the UNBLOCKED path — no bridge/NAT |
| pf network policy | ✅ rulegen | ❌ inter-VM delivery BROKEN (if_bridge) | needs design rethink — see below |
| rctl resource caps | ✅ | ✅ live + orchestrator-guarded | real-node deny proof pending |
| Capsicum device grants | n/a | n/a | bhyve self-confines — no seam |
| Image attestation | ❌ | — | no grammar yet; built from scratch |
| Audit trail | ❌ | — | nothing records node attempts |

### 0. jail nodes — LIVE-PROVEN (the unblocked containment path)
Jails share the host network stack, so the bhyve bridge/NAT bug DOESN'T apply —
this is where aeo's containment is both strongest and now demonstrated live.
Validated 2026-06-25 on the box:
- [x] Populated a jail root (`/zroot/jails/aeo-rj` + `/rescue/{sh,test,ls}`).
- [x] Booted a REAL jail via the exact `driver_bsd` command sequence:
      `jail -c name=aeo-rj path=... host.hostname=aeo-rj persist` → jail CREATED.
- [x] Probed: `jls` shows JID + hostname (driver_bsd.probe path).
- [x] In-jail exec: `jexec aeo-rj /rescue/test -d /` passed; `ls /` shows ONLY
      the jail's own root (dev, rescue) — NOT the host's — i.e. contained.
- [x] Closed the loop: aeo's `jail_create_argv` emits EXACTLY the command that
      worked live (byte-for-byte), and `smoke_bsd` (driver pure-logic) passes.
- [ ] Un-park `test/real_jail.ae` into `test/` — BUT it shells `jail`/`jls`
      directly (driver doesn't self-sudo), so the binary needs to run as root;
      `sudo <arbitrary-binary>` isn't in the NOPASSWD grants. Either: add a narrow
      grant, run it from a root shell, or make driver_bsd self-sudo like driver_vm
      does. (Proven via argv-match + live commands meanwhile.)
- [ ] Apply rctl caps + Capsicum to a live jail node end-to-end (both already
      target jails; combine with the above for a fully-contained jail node).
- [ ] A jail-based apex example (the silly_addition_cache DSL already declares a
      `jail("db")` path) — orchestrate a real jail tree via `aeo up`, no bhyve.

### 1. pf network policy — inter-VM delivery BROKEN, needs design rethink (HIGH)
Rulegen (lib/pf, lib/compose) is correct + unit-tested. The bite-step pf.conf was
applied and host mgmt preserved. BUT the live two-guest behavioral test
(2026-06-25) proved the inter-VM *enforcement path* does not work on the shared
bridge — full writeup in `docs/pf-enforcement-next-steps.md`:
- [x] Behavioral acceptance test RUN — and it FAILED honestly. Found: (a) pf
      doesn't filter bridge traffic by default (`pfil_member=0` → anchor never
      sees inter-VM packets); (b) with `pfil_member=1`, deny-default works but the
      whitelist PASS can't complete a handshake (if_bridge per-member dual
      evaluation drops the stateful return path). Reverted to known-good.
- [ ] **DECIDE the delivery architecture** (this is the fork): per-VM epair +
      routed L3 (pf filters normally, no bridge), vs `pfil_bridge=1` (filter once
      on the bridge), vs guest-side firewall via the resident agent. See doc.
- [ ] Re-run the 4 assertions once a working delivery is chosen (the test harness
      + two guests aeo-base/.50 + testpeer/.51 are proven and reusable).
- [x] Lockout-safety: Paul has console (kbd/display); pf/rctl missteps recoverable.

### 2. rctl resource caps — LIVE (MEDIUM)
`limit{}` grammar + lib/rctl + runner wiring built; `spec_rctl_rulegen` green
(8, incl. the orchestrator-guard). Host prereqs DONE + live-validated 2026-06-25.
- [x] Host prereq: `kern.racct.enable=1` in `/boot/loader.conf` + reboot — done.
- [x] Host prereq: `/usr/bin/rctl` granted in the `aeo-pf` sudoers drop-in.
- [x] Live: `jail:testjail:maxproc:deny=10` added/read-back/removed cleanly on
      the box (RACCT on); orchestrator session untouched.
- [x] **Never-cap-the-orchestrator guard** (lib/rctl `_subject_ok`): refuse
      user/loginclass subjects; only jail/process (node-scoped). Found the hard
      way — a `user:paul` vmem cap locked sshd out and needed a reboot.
- [ ] Behavioral deny on a REAL node: stand a jail with a maxproc cap, prove a
      fork-bomb inside it is refused (the live "it actually contains" proof).
- [ ] Thicken: cap **bhyve-VM** nodes too (v0 caps jails only — needs the
      hypervisor PID → `process:<pid>` targeting). Runner logs "NOT enforced
      (kind=bhyve)" loudly rather than skipping silently.

### 3. Image attestation — supply-chain (HIGH for "impregnable")
NO grammar yet (no `sign` setter exists — built from scratch). Nothing verifies
an image before boot, so a poisoned golden snapshot boots trusted.
- [ ] New grammar: pin an expected digest in the image recipe (e.g.
      `attest("sha256:...")` on the golden snapshot / base image).
- [ ] Verify-at-boot: the driver checks the image/snapshot digest before
      clone-and-boot; reject on mismatch/drift (fail-closed, loud).
- [ ] Decide the trust root (operator-pinned hashes vs. a signing key). Pure
      digest-compare half is unit-testable off-box.

### 4. Audit trail — forensics / "contain malware" observability (MEDIUM)
Nothing records what a node ATTEMPTED — containment blocks but doesn't observe.
- [ ] Emit a tamper-evident log of denied attempts (pf-logged blocks → an aeo
      audit stream; rctl denials; failed egress). `std.audit` is referenced in
      the Capsicum branch design — wire aeo as a consumer.
- [ ] Per-node connection logging on the deny-default pf (which flows were
      refused), so a compromised node's probing is visible, not just stopped.

## Cross-cutting / smaller

- [ ] **Behavioral end-to-end on the box**: one session that does the pf
      bite-step + RACCT reboot, then runs the apex and validates BOTH pf deny
      and rctl deny live (the two pending acceptance tests together).
- [ ] aeo-agent: slices 2–4 (rewrite onto transport_http; container-build the
      Linux agent binary; driver push + init-aware TSR — systemd/OpenRC/sysvinit,
      see memory `aeo-agent-tsr-init-systems`). Slice 1 (lib/transport_http) done.
- [ ] aeo-agent ON WINDOWS: the Bazzite→Chromebook→Win11 build/store/deploy
      pipeline — `docs/aeo-agent-windows-pipeline.md`. Blockers: agent body is
      Linux-bound (needs driver_windows/select arm), not on the conduit yet, and
      the mingw cross-build is unproven (spike it first). Agent stays Aether.
- [ ] Watch aether#878 (qualified-surface-on-any-import); when it lands, the
      aeocha-driven specs can drop their bare `import std.string`. (#870 already
      dropped from the demo.)
