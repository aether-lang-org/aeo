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
| pf network policy | ✅ | ⚠️ chain proven, anchor wired | bite-step deferred |
| rctl resource caps | ✅ | ⏳ pure-tested only | needs RACCT reboot + grant |
| Capsicum device grants | n/a | n/a | bhyve self-confines — no seam |
| Image attestation | ❌ | — | `sign` grammar exists, unused |
| Audit trail | ❌ | — | nothing records node attempts |

### 1. pf network policy — finish enforcement (HIGH)
Built + chain-proven live; the `anchor "aeo/*"` line is wired into the box's
`/etc/pf.conf`. **Not yet biting** — the blanket `pass quick on vm-aeonat all`
short-circuits the anchor.
- [ ] Apply the bite-step pf.conf (remove the blanket inter-VM pass). Procedure
      + parse-checked config + rollback in `docs/pf-enforcement-next-steps.md`.
      ⚠️ blast radius: do it when no guests are mid-deploy.
- [ ] Behavioral acceptance test (the real proof): deploy the apex, confirm
      python_vm→db_vm:6379 ALLOWED, non-whitelisted port DENIED, a 3rd VM
      DENIED, db_vm egress (deny_egress) DENIED, host→guest ssh still works.
- [ ] **Open design question (Paul):** avoid global `/etc/pf.conf` entirely?
      Alternatives to weigh first — a dedicated aeo bridge with its own
      default-deny, or per-tap filtering. (Captured in the next-steps doc.)

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
The `sign` grammar exists but nothing verifies an image before boot, so a
poisoned golden snapshot boots trusted.
- [ ] Hash-pin the golden snapshot (record expected digest in the recipe).
- [ ] Verify-at-boot: the driver checks the image/snapshot digest before
      clone-and-boot; reject on mismatch/drift (fail-closed, loud).
- [ ] Decide the trust root (operator-pinned hashes vs. a signing key) and wire
      `sign` to it. Pure digest-compare half is unit-testable off-box.

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
- [ ] Watch aether#878 (qualified-surface-on-any-import); when it lands, the
      aeocha-driven specs can drop their bare `import std.string`. (#870 already
      dropped from the demo.)
