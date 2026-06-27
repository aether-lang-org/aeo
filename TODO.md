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
| **Linux container confinement** | ✅ | ✅ **cgroups+cap-drop+netpolicy, fork-bomb refused live** | lib/confine_linux; reuses limit{}+constrain{} grammar (§5) |
| Image attestation | ✅ | ✅ **verify-before-boot, fail-closed; wrong digest refused live** | attest("sha256:..."); 3 greppable states (attested/unpinned/unattestable) |
| Audit trail | ✅ | ✅ **tamper-evident hash chain; tamper + attest-refuse caught live** | lib/audit; `aeo audit` verifies the chain (§4) |

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
- [x] **driver_bsd self-sudo** — jail/jls/jexec/zfs now run via `sh -c "sudo -n
      <prog> <squoted-args>"` (a `_sudo_run` helper, like driver_vm), so the aeo
      binary no longer needs to be root. Paths match the box sudoers exactly
      (/usr/sbin/jail family + /sbin/zfs). smoke_bsd green; argv builders
      unchanged (the tested pure surface).
- [x] **Un-parked `test/real_jail.ae`** into `test/` — now a normal spec (runs
      unprivileged; the sudo is inside the driver). Builds + fails gracefully off
      FreeBSD; runs for real on the box (needs a populated jail root via
      setup-jail-root.sh). Box-validate when it's back.
- [x] Apply rctl caps to a live jail node end-to-end: booted db+app jails on the
      box, applied the demo's exact rules (jail:db:memoryuse:deny=512M, maxproc
      32; jail:app:maxproc 128), kernel accepted, read back, cleaned up. The
      jail-boundary + rctl axes BOTH live on real nodes.
- [x] **A jail-based apex example** — `examples/silly_addition_jails.ae`, the
      sibling of silly_addition_bhyve_podman.ae: two rctl-capped jails (db <- app),
      all-in-one (check/up/suite). check 3/3 standalone; both build doors green;
      live suite assertions (jls running + `jexec ls /` shows only the jail root,
      not /home) validated on the box.
- [ ] Capsicum-in-jail on the live node (spec_capsicum_jail_selfreport proves the
      mechanism; combine with the demo for the full three-axis showcase).
- [ ] Run the jail demo's `up`/`suite` via real `aeo up` once driver_bsd can run
      privileged (self-sudo or a root grant) — same blocker as real_jail.ae.

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

### 3. Image attestation — DONE + LIVE (lib/attest, 2026-06-27) — supply-chain
- [x] **Grammar**: `attest("sha256:...")` pins a node's expected image digest.
- [x] **Verify-at-boot, FAIL-CLOSED**: the runner resolves the image's ACTUAL
      digest, refuses on mismatch (loud), runs image@<digest> so podman enforces
      the pin too. LIVE: correct pin boots by-digest; WRONG pin -> "DIGEST
      MISMATCH ... refusing to boot", container refused.
- [x] **3 greppable states** (Paul's audit idea): attest_state -> "attested" |
      "unpinned" (pulled, no pin — a finding) | "unattestable" (built from
      entrypoint/dockerfile — no upstream digest). In `aeo status` + `--json`
      (attestation/attest_digest fields) so a CI gate can fail on
      attestation!="attested". spec_attest 5.
- [ ] Follow-up: trust root beyond operator-pinned hashes (cosign/skopeo are on
      Bazzite — a signature path). Also: attest a qcow2 / jail-dataset hash
      (same shape, swap the digest probe) so attestation spans substrates.

### 4. Audit trail — DONE + LIVE (lib/audit, 2026-06-27) — forensics
Containment BLOCKS; the audit trail OBSERVES. Append-only, HASH-CHAINED log of
every security DECISION aeo makes per node.
- [x] **record + hash chain**: each entry hash = sha256(prev + payload); editing/
      deleting any past line breaks the chain. Events: attest-pass/attest-refuse
      (supply-chain verdict) + confine (the posture). LIVE: confined demo recorded
      both nodes' exact posture, chained.
- [x] **`aeo audit` verify**: walks the chain, reports INTACT or "CHAIN BROKEN at
      N". LIVE: edited the log to hide db's --network none -> CAUGHT. A bad-digest
      boot recorded as attest-refuse. spec_audit 5.
- [x] NB: distinct from std.audit (Aether's in-process SANDBOX permission ring) —
      this is aeo's INFRASTRUCTURE audit.
- [ ] Follow-up: arrival timestamps (Date.now is unavailable in scripts — the
      sink/caller stamps); pf-logged blocks / rctl denials as events (FreeBSD
      side); per-node connection logging on the deny-default.

### 5. Linux container confinement — DONE + LIVE (lib/confine_linux, 2026-06-27)
The rootless Linux peer of the FreeBSD Capsicum/rctl/pf axes — and it REUSES the
same grammar (limit{} + constrain{}), so confinement is substrate-portable (the
driver picks rctl/Capsicum/pf on FreeBSD vs cgroups/seccomp/network on Linux).
- [x] **cgroup caps** (rctl peer): limit{} -> --memory / --pids-limit / --ulimit.
      LIVE: fork-bomb in db REFUSED by --pids-limit 32 ("can't fork: Resource
      temporarily unavailable").
- [x] **seccomp / cap-drop** (Capsicum peer): a constrain{} node -> --cap-drop
      ALL + --security-opt no-new-privileges (+--read-only on deny_egress). LIVE:
      podman inspect shows db CapDrop=ALL.
- [x] **netpolicy** (pf peer): deny_egress() -> --network none. LIVE: db has no
      network namespace — can't phone home. (Per-flow egress/ingress whitelist
      beyond on/off is a follow-up — podman has no per-flow filter without extra
      tooling; --network none vs shared is the v0 deny-default. NB: podman nets
      are routed/NAT'd not bridged, so the richer policy MAY sidestep the FreeBSD
      pf+if_bridge bug — worth revisiting for that.)
- [x] **grammar reuse achieved**: limit{}+constrain{} render to BOTH substrates.
      lib/confine_linux (spec_confine_linux 10); driver_linux up_confined;
      runner._confine_flags. Demo: examples/silly_addition_confined.ae.
- [ ] Follow-up: per-flow container netpolicy (egress(target,port)/ingress_from)
      — the v0 is on/off (--network none vs shared). Also: --cpus from pcpu.

## Lifecycle & state ops (snapshot / rollback / backup / prune / exec / restart)
Day-2 operability for a STANDING deployment: capture point-in-time state, restore
it, retain it, and reach into / restart individual nodes — without becoming a
platform (no web UI, no daemon, no HA — those cross the "aeo is not a platform"
line). Config-is-code intact. Proxmox is the comparison, not the goal: these are
aeo's own verbs; the inline "Proxmox-X" notes just point at the familiar analog.
- [x] **snapshot/rollback** — `aeo snapshot|rollback <compose.ae> [tag]` over each
      node's ZFS dataset (lib/snapshot; jail=declared dataset, bhyve=zroot/vm/<n>).
      Pure logic spec'd (spec_snapshot, 6); live zfs box-validated later.
- [x] **enriched `aeo status`** — per node now shows ip / rctl caps / pf netpolicy
      / Capsicum grants / snapshots, only where set. Live state still driver-probed.
- [ ] Live-validate snapshot/rollback on the box (zfs snapshot a jail, roll it
      back) once it's back from the storm. [the FreeBSD/ZFS side — still pending;
      box is on Bazzite. The LINUX side is now done + live, see below.]
- [x] **Linux-side operability** (lib/snapshot_linux) — snapshot/rollback/backup/
      prune for container/kvm/lxc (the verbs were ZFS-only). container = podman
      commit -> image; kvm = qemu-img snapshot; lxc = lxc-snapshot. Runner
      dispatches on kind. LIVE on Bazzite 2026-06-27: container round-trip proven
      (snapshot -> change /marker.txt -> rollback -> restored), backup -> real
      .tar artifacts. spec_snapshot_linux 3.
      - [x] kvm validated 2026-06-27: offline snapshot (v1/v2 on a qcow2) + PRUNE
            keep-N (seeded a/b/c, keep=2 -> {b,c}, dropped oldest). FOUND: kvm
            snapshot is OFFLINE-ONLY — qemu write-locks a running VM's qcow2
            ("Failed to get shared write lock"), unlike ZFS/podman (live). The
            driver now returns an actionable "aeo down first" message (_qemu_offline).
      - [x] lxc validated 2026-06-27 (lxc-snapshot/lxc-copy sudoers grant added):
            snapshot @v1 -> snap0 (both containers, offline stop->snap->start, both
            RUNNING after); rollback snap0 -> /marker.txt restored. FOUND: lxc-
            snapshot is OFFLINE + AUTO-NAMES (snap0, not operator tags) — the driver
            now does stop->snap->start and restores by snapN. ALL THREE Linux
            substrates (container/kvm/lxc) now live for lifecycle ops.
- [x] **`aeo status --json`** — machine-readable status (flat array of node
      objects: name/kind/system/host/depends/state/ip/caps/netpolicy/grants).
      Validated through a real JSON parser on both demos (paths/<-/= chars
      escape cleanly). The Proxmox-API value without the web server: pipe to jq/
      a dashboard/a CI gate.
- [x] **per-node lifecycle** — `aeo exec <compose.ae> <node> <cmd>` runs a command
      IN one node (jail=jexec, bhyve=ssh, container=podman-exec, nested=ssh-to-host
      +podman); `aeo restart <compose.ae> <node>` down+ups a SINGLE node without
      touching the tree (Proxmox per-VM stop/start). Per-kind driver_exec()
      dispatch + driver_{bsd,vm}.exec_capture(); clean error handling (unknown/
      missing node/cmd). Built + dispatch-tested here; live on box.
- [x] **backup + prune** — `aeo backup <compose.ae> <tag> [dir]` zfs-sends each
      node's @tag snapshot to a portable `<dir>/<node>-<tag>.zfs` stream
      (restore = `zfs receive`); `aeo prune <compose.ae> [keep]` keeps the N
      newest-by-CREATION snapshots per node, destroys older. Composable verbs
      (operator snapshots, then backups/prunes). Backup surfaces failures + cleans
      up partial artifacts (no false success). backup_file path unit-tested
      (spec_snapshot, 8); live zfs send/destroy box-validated later.
- [ ] NOT doing (against the grain, design-doc line): web UI, clustering/multi-
      host default, live migration, HA. A `driver_proxmox` (orchestrate a Proxmox
      host as a substrate) is the aeo-shaped alternative if that itch returns.

## Resource-kind coverage (which `kind`s are real vs demo'd)

aeo's grammar exposes 6 kinds + a flavor. Demo'd: container/jail/bhyve/kvm/lxc.
Gaps:
- [x] **`lxc` is now REAL** — was a misnomer (routed to podman). driver_lxc built
      + wired (runner up/down/probe/exec) + silly_addition_lxc.ae; LIVE on Bazzite
      2026-06-27 (rootful via the lxc-* NOPASSWD sudoers grant + `systemctl enable
      --now lxc-net` for lxcbr0). `aeo up`->two alpine system containers RUNNING,
      `aeo exec db hostname`->"db" (contained), `aeo down` clean. (busybox template
      fails — no busybox binary on the host; the download/alpine template works.
      Rootless LXC stays blocked on this atomic host — rootful is the path.)
- [ ] **PORT the self-sudo argv fix to driver_bsd** — driver_bsd._sudo_run has
      the SAME latent bug driver_lxc hit: it interpolates argv with "${a}" into an
      `sh -c` string, yielding the element ADDRESS not the string. Its argv
      builders are unit-tested but the live self-sudo path apparently never ran for
      real. Fix: pass argv DIRECTLY to run_capture("sudo", [...]) with list_add_raw
      ptr-copy (as driver_lxc now does, like driver_vm's qemu exec). Until then,
      jail/jls/jexec via driver_bsd self-sudo would mangle their args live.
- [ ] **`docker` kind** — thin: same as container but pins the docker engine. No
      demo; arguably container covers it. Low priority.
- [ ] **`freebsd_vm`** — a bhyve VM with a FreeBSD GUEST (flavor "freebsd"); the
      bhyve demos run Linux guests. A real cell (FreeBSD-native VM / jails-in-VM),
      trivially close to the bhyve demo. No demo yet.
- [ ] **Nesting depth** — the demo grid is flat (1-level: container-in-VM). aeo's
      design is RECURSIVE (the tree-of-nodes / aeo-agent recursion). No demo of
      jail-in-VM, VM-in-VM, or 3+ tier.

### Lighter-tier substrates (smaller VMs + sandboxes) — future kinds
Surveyed both boxes 2026-06-27. Below what aeo drives today (full-qemu kvm,
podman, LXC) sits a lighter tier — smaller VMs and unprivileged sandboxes. None
wired yet; mapped here as candidate kinds. Ordered by how cleanly they'd land:
- [ ] **bwrap (bubblewrap)** — the STANDOUT. Unprivileged sandbox (the Flatpak
      engine); installed on both boxes and proven to run ROOTLESS with zero host
      setup — no sudoers, no systemctl, no idmap/bridge dance (unlike jails/kvm-
      tap/LXC, which all needed grants + console). A driver_bwrap = aeo's
      no-privilege "contain this process" tier, runnable anywhere. Directly serves
      the containment thread without the host-config friction that's blocked us.
- [ ] **systemd-nspawn** — a systemd-native system container (LXC's tier) but far
      less finicky: a rootfs + nspawn, no idmap/lxcbr0. Installed on both boxes;
      needs root. Possibly the LESS painful system-container path than driver_lxc.
- [ ] **Firecracker** — the canonical "smaller VM": AWS microVM, ~125ms boot,
      minimal device model vs full qemu. A genuinely distinct VM substrate (the
      `kvm` kind is full-qemu). NOT installed — needs install + /dev/kvm.
      Cloud-hypervisor / crosvm are the same rust-vmm niche (crosvm IS ChromeOS's
      VMM, not exposed to Crostini). More setup before a driver than bwrap/nspawn.
- [ ] **Raw primitives** — unshare (namespaces), chroot (the oldest container).
      Too low-level to be node kinds on their own; bwrap is the usable wrapper.

## Cross-cutting / smaller

- [ ] **Weave aether DURATION LITERALS into the aeo DSL** (Paul 2026-06-27).
      Aether has first-class duration literals — `2000ms`, `10s`, `200ms` —
      typed `Duration` (i64 ns), verified to compile in aeo's toolchain. aeo's
      time-ish setters take raw int MS today: `health_interval(ms: int)`,
      `health_budget(n)`, and the new netpolicy connect-timeout. Replacing those
      with Duration-typed setters (`health_interval(1s)` not `(1000)`) is a real
      ergonomics + correctness win (no more "is this ms or s?"). Plan: a Duration
      param + a `_dur_ms(d)` that converts to the int ms config stores; keep an
      int overload for back-compat. Start with health_interval; the netpolicy
      egress() could take an optional connect-timeout as a Duration.

- [x] **NOT A BUG: "single-container doesn't boot" was a test-harness artifact.**
      Investigated 2026-06-27 and traced to the END: a 1-node compose DOES boot
      fine (`aeo up justdb.ae` -> [db] up -> container RUNNING). The earlier
      "quirk" was MY fault — test demos written via SSH heredocs with `\"` inside
      double-quoted commands landed on the box with BACKSLASH-ESCAPED quotes
      (`system(\"justdb\")`), so `system()`/`container()` got mangled names,
      resources registered under bad keys, and `compose.count()` came back 0 ->
      run_up's loop did nothing -> vacuous "stack up". Clean-quoted files (all the
      real demos, and any scp'd file) register + boot correctly. LESSON: write
      .ae test files locally + scp them, or use a quoted heredoc delimiter
      (`<<'EOF'`) — never an unquoted SSH heredoc with `\"`.
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
