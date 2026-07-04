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
- [x] **per-flow container netpolicy** — DONE + LIVE 2026-06-27. 3 tiers via
      podman per-network isolation: deny_egress->none, peer egress->--internal net
      (reach peers by name, NOT the internet), ingress/none->shared. net_kind
      classifies; egress targets pulled onto the internal net. LIVE: app
      (egress->db) reaches db but CANNOT reach the internet. SIDESTEPS the pf+
      if_bridge bug (§1) — podman routed nets, no bridge filter. spec 12.
- [ ] Follow-up: --cpus from pcpu (limit_cpu); finer ingress_from peer-scoping
      (v0 internal-net is per-system, not per-pair).

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
- [~] **`engine()` property — CORE BUILT + LIVE-PROVEN 2026-07-04; examples pending
      (Paul migrating). See fable-5-insights.md §D.** DONE: compose `engine()` verb
      (system-float + node override, snapshotted at decl like within/every) +
      `get_engine()`; deleted docker/windows/wslc KIND-verbs; rerouted all runner
      dispatch (up/exec/down/probe + batch-liveness `_level_has_engine`) to key on
      `container` + resolved engine; deleted dead `_engine_of`/`_level_has_batch_kind`.
      Both Windows DRIVERS kept (engine value = driver selector: wslc→driver_wslc,
      wsl_podman→driver_windows). LIVE on bazzite (podman 5.8.2 + docker 29.5.3):
      `engine()` float+override verified (system engine("docker") floats, node
      engine("podman") overrides); the DOCKER-SECOND-CLASS BUG FIXED — an
      engine-pinned container now gets `--memory 128m --pids-limit 16` + the shared
      `aeo-<system>` network (podman inspect confirmed mem=134217728 pids=16
      nets=aeo-engine_demo), which the old plain-up() docker path dropped. 22 spec
      files pass, no regression. STILL TODO: (a) examples migrate docker()→
      container(){engine("docker")} + collapse windows/wslc examples [Paul];
      (b) host-family gate `_kind_runnable` still linux-blocks `container` — a WSL-
      engined container needs the node's engine to skip the linux gate (driver
      available() is the real check); (c) the mixed-engine-per-system network-plane
      WARNING (podman vs docker nets can't resolve peers by name) not yet emitted;
      (d) describe_tree command= surfacing for WSL-engine containers.
      --- original design note ---
      `container()` stays the one OCI kind; new `engine("podman"|"docker"|"wslc")`
      node property with SYSTEM-SCOPE FLOAT + node override (same FluentSelenium
      float machinery as within/every). Auto default per host family: Linux →
      podman → docker; Windows → wslc → podman-through-WSL. `engine()` does NOT
      admit lxc (fails the swap test: image namespace, expose, env, init-vs-command
      — a kind, not an engine). DELETE `docker()`/`wslc()`/`windows()` kind-verbs
      outright — no aliases (pre-1.0, no back-compat; Paul 2026-07-04). Container-
      on-Windows = host-family engine resolution; the windows/wslc examples
      collapse into "containers.ae on a Windows host". Kinds staying OUTSIDE
      container(): lxc, nspawn (which also don't merge with each other), bwrap,
      jail, kvm_vm/bhyve_vm/freebsd_vm/firecracker. FIXES A REAL BUG en route: the `docker` kind's dispatch is
      second-class today — plain `up()`, silently losing the shared aeo-<system>
      net, env() pairs, and ALL limit{}/constrain{} rendering that `container`
      gets via up_confined(). Also: warn loudly when ONE system mixes engines —
      podman and docker networks are separate planes; cross-engine peers can't
      resolve by name (motivating scenario: one Debian host, three systems on
      docker/podman/lxc respectively).
- [ ] **`freebsd_vm`** — a bhyve VM with a FreeBSD GUEST (flavor "freebsd"); the
      bhyve demos run Linux guests. A real cell (FreeBSD-native VM / jails-in-VM),
      trivially close to the bhyve demo. No demo yet.
- [ ] **GENERAL container nesting — the Proxmox docker-in-LXC pattern (see
      fable-5-insights.md §E)**. Homelab ground truth (XDA Jul-2025 + many
      others): OCI-engine-inside-LXC is mainstream — cheap on weak hardware, and
      LXCs can SHARE a GPU/PCIe device across consumers where VM passthrough is
      exclusive. aeo already has the seam: every host-capable kind exposes
      exec_capture (ssh / lxc-attach / systemd-run --machine / jexec) — nested
      bring-up IS "the child engine's commands through the host's exec seam"; the
      VM-only guest_container_up is just one instance. Work: (1) make `lxc()`/
      `nspawn()` block-host openers (set curhost) so
      `lxc("dockerbox"){ container("web"){ engine("docker") } }` declares the
      pattern; (2) route nested bring-up by the HOST's kind, generalizing
      guest_container_up over driver_exec; (3) resident aeo-agent-in-LXC (the
      containment-correct delegate path, same as agent-in-VM); (4) record per-host
      prereqs honestly (lxc nesting=1; privileged for NFS/CIFS volumes; engine
      installed in the guest userland — the "seed installs podman" story);
      (5) compose-time nesting-matrix validation: host-kind × child-kind cells
      gated on "exec seam + child runtime can run there", loud at `aeo check`.
- [ ] **Nesting depth** — the demo grid is flat (1-level: container-in-VM). aeo's
      design is RECURSIVE (the tree-of-nodes / aeo-agent recursion). No demo of
      jail-in-VM, VM-in-VM, or 3+ tier. (Subsumes into the general-nesting item
      above once that lands: depth is just repeated application of the exec seam.)
- [ ] **`gpu(mode)` — device claims with CHECKED allocation semantics (see
      fable-5-insights.md §G)**. The XDA article's sharpest point: VM passthrough
      is EXCLUSIVE (VFIO detaches the device from host + all other consumers);
      LXC/container device-mapping is SHARED (many consumers on one iGPU). Coin
      `gpu("shared"|"exclusive")` (+ optional `gpu_device(pin)`; `"slice"`
      reserved for MIG/SR-IOV) as a claim beside cpus()/memory(), rendered via
      the grant machinery + recorded in the audit trail. Per-substrate: podman
      `--device /dev/dri`/CDI, docker `--gpus`, wslc `--gpus` (already in its
      run flags), lxc cgroup-allow + /dev/dri mount, kvm/bhyve VFIO/ppt
      (exclusive only), jail devfs, bwrap --dev-bind; REFUSE at check on
      firecracker (no device model) and `shared`-on-VM (until vGPU). Check-time
      allocation: exclusive ∩ anything on one device = FAIL with the tier-choice
      explanation — the article's human decision becomes a machine-checked
      constraint. Host preflight probes the device exists.
- [ ] **`nested_virt()` — deny-by-default, attenuate-down-the-tree (see
      fable-5-insights.md §H)**. Principles of containment: capability must
      attenuate down the tree, never flow down implicitly — a node with nested
      virt can spawn sub-VMs aeo can't see (breaks tree-is-truth; the
      deny_egress twin for compute capability). Explicit per-node grant, NO
      float-down (each level re-declares). Deny = ACTIVE masking even when the
      substrate leaks it: `-cpu host,-vmx,-svm` for child VMs; no /dev/kvm map +
      cgroup device-deny for containers/lxc; `[wsl2] nestedVirtualization=false`
      for the WSL tier. Check-time CHAIN validation (host nested=1 → VM vmx →
      container /dev/kvm; break anywhere = loud fail — the ladder we hand-debugged
      on bazzite for the Win11→WSL2→podman 3-deep proof). Refused on
      firecracker/jail (ungrantable, by construction). Grants audited. Doctrinal
      point: a node needing children should DECLARE them (agent delegate path),
      not freelance with raw /dev/kvm — deny-default forces sprawl into the tree.

### Lighter-tier substrates (smaller VMs + sandboxes) — future kinds
Surveyed both boxes 2026-06-27. Below what aeo drives today (full-qemu kvm,
podman, LXC) sits a lighter tier — smaller VMs and unprivileged sandboxes. None
wired yet; mapped here as candidate kinds. Ordered by how cleanly they'd land:
- [x] **bwrap (bubblewrap)** — the STANDOUT. Unprivileged sandbox (the Flatpak
      engine); installed on both boxes and proven to run ROOTLESS with zero host
      setup — no sudoers, no systemctl, no idmap/bridge dance (unlike jails/kvm-
      tap/LXC, which all needed grants + console). A driver_bwrap = aeo's
      no-privilege "contain this process" tier, runnable anywhere. Directly serves
      the containment thread without the host-config friction that's blocked us.
      DONE (2026-06-29): lib/driver_bwrap (kind `bwrap`) wired through the runner
      (up/down/probe/exec + linux host-gating) and the compose DSL verb. bwrap has
      no daemon/named-container registry, so the driver tracks each sandbox by a
      PIDFILE like driver_vm/kvm: up backgrounds `bwrap --unshare-all --new-session
      <binds> -- /bin/sh -c CMD` (host userland ro-bound, or image() rootfs as /);
      net unshared = deny_egress for free. command() is required (a sandbox has no
      image init). exec/probe-health run a FRESH identically-confined bwrap (no
      unprivileged re-attach exists). PURE half (sandbox_argv + the sh-quoting)
      unit-tested off-box: test/spec_bwrap.ae + 9/9 on the macOS dev box. Example:
      examples/silly_addition_bwrap.ae (PID-1 containment proof). LIVE up/probe/
      exec still need a Linux box: run test/smoke_bwrap.ae where `bubblewrap` is
      installed (it SKIPs cleanly off-Linux). Headline win realized: the only host
      prereq is `apt/dnf install bubblewrap` — no sudoers, no bridge.
- [x] **systemd-nspawn** — a systemd-native system container (LXC's tier) but far
      less finicky: a rootfs + nspawn, no idmap/lxcbr0. Installed on both boxes;
      needs root. Possibly the LESS painful system-container path than driver_lxc.
      DONE (2026-06-30): lib/driver_nspawn (kind `nspawn`) wired through runner +
      compose DSL. machined-managed (no pidfile): up runs `systemd-run
      --unit=aeo-nspawn-NAME systemd-nspawn --machine=NAME --directory=ROOTFS`
      with `--boot` (full system container) by default, or the node's command()
      as the payload via `--as-pid2`. probe = `systemctl is-active`; exec =
      `systemd-run --machine=NAME --pipe`; down = `machinectl terminate` + stop
      the unit. Self-sudo (systemd-run/systemctl/machinectl NOPASSWD), mirroring
      driver_lxc. image() is the (required) rootfs dir. PURE half (the argv
      builders) unit-tested off-box: test/spec_nspawn.ae + a standalone harness on
      macOS. LIVE up/probe/exec needs a real SYSTEMD host: run test/smoke_nspawn.ae
      on Bazzite (nspawn refuses Docker's /run layout, so no Docker proof — it
      SKIPs cleanly off a systemd host). Example: examples/silly_addition_nspawn.ae
      (hostname-containment proof). Follow-up: rootfs provisioning (today image()
      must point at an already-populated /var/lib/machines/<name>; lxc gets its
      from the download template — nspawn could grow a machinectl pull-tar path).
- [x] **Firecracker** — the canonical "smaller VM": AWS microVM, ~125ms boot,
      minimal device model vs full qemu. A genuinely distinct VM substrate (the
      `kvm` kind is full-qemu). Cloud-hypervisor / crosvm are the same rust-vmm
      niche (crosvm IS ChromeOS's VMM, not exposed to Crostini).
      DONE (2026-06-30): lib/driver_firecracker (kind `firecracker`) wired through
      runner + compose DSL. No daemon/named-VM registry, so it's pidfile-tracked
      like the kvm arm of driver_vm: up writes a config.json (boot-source=vmlinux,
      drive=rootfs.ext4, machine-config=vcpus/mem from cpus()/memory()) and
      backgrounds `firecracker --api-sock SOCK --config-file CONFIG`; down SIGTERMs
      the pid + drops socket/config; probe = pid alive. image() names a BUNDLE DIR
      holding `vmlinux` + `rootfs.ext4` (one field, both artifacts). The pure
      builders (config_json/mem_mib) are unit-tested (test/spec_firecracker.ae) AND
      the generated config is SCHEMA-PROVEN against the real firecracker v1.10.1
      binary in Docker — it accepts the config, machine-config, and both drives,
      advancing to kernel-load (only a dummy-kernel magic-number error stops it; a
      real vmlinux + /dev/kvm boots). Example: examples/silly_addition_firecracker.ae.
      LIVE boot needs a KVM host: run test/smoke_firecracker.ae where /dev/kvm +
      firecracker + a bundle exist (it SKIPs otherwise; Docker-on-macOS has no
      /dev/kvm). KNOWN GAPS / follow-ups: (1) exec_capture is a no-op — a microVM
      has no host-side exec; reaching the guest needs ssh/vsock over a tap (the
      driver_vm ssh shape). (2) No networking yet (bare boot; a tap/CNI for guest
      egress is next). (3) Artifact provisioning — image() must point at a
      prebuilt vmlinux+rootfs bundle today.
- [ ] **microsandbox (`msb`) — fast local microVMs for UNTRUSTED workloads**
      (github.com/superradcompany/microsandbox, Apache-2.0, libkrun+smoltcp).
      An almost-tailor-made fit for aeo's *purpose* ("orchestrated trees that
      contain malware and are impregnable"): microVM hardware isolation, but with
      **OCI images** (Docker Hub/GHCR) and Docker-like workflows, ~**<100ms boot**,
      **cross-platform** (Linux KVM / macOS Apple-Silicon / Windows WHP), and
      **embeddable** (no daemon, no server — `Sandbox::builder(...).create()`
      spawns a microVM as a child process).
        - **New driver tier `driver_microsandbox` (kind `microsandbox`)**: the CLI
          maps cleanly onto aeo's driver shape — `msb create --name N <image>` /
          `msb start|stop|rm N` (lifecycle), `msb exec N -- <cmd>` (exec_capture),
          `msb ps N` / `msb inspect N` (probe), `msb pull` (image). cpus()/memory()
          → the builder's `.cpus()/.memory()`. It's the microVM tier that ISN'T
          artifact-bound like firecracker (which needs a prebuilt vmlinux+rootfs) —
          microsandbox takes a stock OCI image, so no bundle provisioning. Likely
          the LEAST-friction strong-isolation tier after bwrap.
        - **Where it beats the existing tiers**: firecracker gives microVM
          isolation but needs hand-built artifacts + has no networking/exec yet;
          microsandbox gives the same isolation class WITH OCI images, built-in
          networking (smoltcp), exec, and detached long-running mode — i.e. it's
          firecracker's isolation with podman's ergonomics. And it's the one tier
          that spans all three OSes uniformly (relevant to the Windows arm + wslc
          items above).
        - **Cross-cutting wins to fold in**: "secrets that can't leak" (keys never
          enter the VM) is an attestation/forensics property worth a self-attest
          axis (§5.4); detached long-running sandboxes suit the aeo-agent resident
          model; and its MCP server / Agent-Skills are orthogonal but note-worthy
          (an agent could drive aeo which drives microsandbox).
        - Requirements to gate on: Linux KVM / macOS Apple-Silicon / Windows WHP;
          BETA (expect breaking changes — pin a version). Spike: does the SDK/CLI
          expose per-sandbox resource caps + network-deny that render the
          `limit{}`/`constrain{}` grammar (substrate-portable confinement)?
- [ ] **Raw primitives** — unshare (namespaces), chroot (the oldest container).
      Too low-level to be node kinds on their own; bwrap is the usable wrapper.

## Cross-cutting / smaller

- [ ] **A secrets engine — encrypted-throughout, never plaintext in state/logs**
      (transfer from Pulumi's model; the one idea from their talk that's a real
      aeo gap). Today aeo has attestation + a tamper-evident audit trail but NO
      secrets story — and the bank-courier agent token is currently plaintext in
      env + baked into the cloud-init seed (readable on the seed ISO). The Pulumi
      shape is right for aeo:
        - A secret is a TYPED value that stays CIPHERTEXT in aeo's own state
          (std.config / the audit inputs) and is decrypted ONLY at the boundary
          where it's used (the agent dial, the driver spawn) — never logged, never
          in a snapshot/backup artifact in the clear.
        - PLUGGABLE key backend (Pulumi does its own KMS by default, swap in
          AWS/GCP KMS or Vault). aeo's peer: a default local key + an operator hook
          to a real KMS/age/gpg — mirroring how drivers self-sudo to operator-
          granted binaries rather than owning the trust root.
        - Concrete first cut: courier the agent token as a secret — mint it,
          encrypt it into the seed (agent decrypts at boot with a key delivered by
          the ssh courier, not the seed), so a captured seed ISO doesn't leak the
          token. Ties into the bank-courier auth (lib/agent_auth) + audit.
        - Guard: this is aeo's OWN secret handling, NOT a general secrets manager —
          scope it to what the orchestrator itself must hold (tokens, image-pull
          creds), not user-workload secrets (those are the workload's problem).
- [ ] **Component compositions as versioned, testable API objects** (lighter
      Pulumi transfer). aeo's compose DSL is already closure-with-setters, but the
      pattern worth borrowing is *operator packages a component (e.g. a confined
      db-tier or a whole subtree), devs consume it by name/version, refactor +
      test it like real code* — an ops/dev separation where the confinement +
      attestation live IN the packaged component so a consumer can't accidentally
      deploy it unconfined. aeo's `.ae`-you-run already allows this (import a
      module that returns a configured subtree); make it a blessed pattern +
      example, not a new mechanism. NOT Pulumi's SaaS-state/component-registry —
      just the "confinement travels with the component" ergonomic.
      (Explicitly NOT doing from the Pulumi talk: cloud-provider CRUD, SaaS state
      backend, terraform import, IAM-JSON helpers, general IaC language — that's
      Pulumi's grain, not aeo's. aeo is config-IS-code for a CONTAINMENT tree, not
      a cloud-resource graph. Keep the seam sharp, same as aeo-is-NOT-aeb.)

- [ ] **pasta port-forwarder for rootless containers — preserve true source IP**
      (podman 6, `rootless_port_forwarder = "pasta"`). Directly serves aeo's
      rootless-containment thesis: without it, a rootless container behind a
      reverse-proxy node sees the PROXY's internal IP, not the real client — which
      breaks any IP-based defense (brute-force lockout, IP banning) and pollutes
      the audit trail with useless source addresses. With pasta, the true source IP
      survives into the container.
        - **Config, not code**: a drop-in `/etc/containers/containers.conf.d/*.conf`
          with `[network]\nrootless_port_forwarder = "pasta"`. driver_linux could
          write/verify this drop-in as part of an "ingress" or `expose()` posture,
          OR aeo just documents it as a host prereq (like the sudoers grants).
        - **Confinement/forensics angle**: source-IP fidelity is an AUDIT property —
          a `constrain{}`/ingress node whose logs show the real client is
          meaningfully more defensible. Worth a self-attest axis later (§5.4): "is
          the true source IP reaching this node, or a proxy's?".
        - **KNOWN BUG to guard**: forward rules aren't torn down cleanly on
          container shutdown → conflicts on restart (podman-container-tools/podman
          #29032). aeo's teardown VERIFIES disappearance — so aeo's reverse-order
          teardown should explicitly clear stale pasta forward rules before a
          restart, or the node fails to come back up. Test this in the
          container-restart path (lib/snapshot_linux / lifecycle ops).
        - Note: needs podman ≥ 6 (still marked experimental); the box is on 4.3.1
          (in-guest) — check host podman version before relying on it.
      Sequencing: small + high-value for any real ingress/reverse-proxy topology
      (which the blue-green cutover below will also want).

- [ ] **Blue-green upgrades (zero-downtime node/tree cutover)** — orchestration,
      not just lifecycle ops. Upgrade a node (or subtree) by standing the NEW
      version up ALONGSIDE the old (green beside blue), health-gating it to
      readiness, cutting traffic/dependents over, verifying, THEN tearing down the
      old — with rollback to blue if green fails its health window. Where it lands:
        - Leans on machinery aeo already has: health-gated bring-up (the
          within/every window), the reverse-order verified teardown, and
          snapshot/rollback (lib/snapshot*) for the fallback.
        - The agent path makes the nested case honest: to blue-green a container
          nested in a VM, the resident agent stands up green inside the guest and
          swaps — the orchestrator never reaches through the boundary. `delegate`
          + `status` + a new `retire`/`cutover` verb is the natural protocol shape.
        - Confinement invariant: green must come up ATTESTED + CONFINED before any
          cutover (self-attest, §5.4) — a blue-green swap must not be a hole where
          an unconfined node briefly serves.
        - Open design: cutover mechanism per substrate (DNS/port-forward re-point,
          dependents' env re-resolve, or an in-guest reverse-proxy the agent owns);
          and whether "green beside blue" needs distinct IPAM/ports (it does — the
          addressing convention already assigns per-node ports).
      Sequencing: after the agent path is the blessed default and a real workload
      runs in the child (both currently opt-in / NOOP). This is the marquee
      operational feature the agent architecture unlocks.

- [x] **PARALLEL bring-up — the detached single-poller engine** (2026-07-01) —
      run_up() used to boot serially: spawn a node, block until it is up, THEN
      start the next — O(N) even for N INDEPENDENT nodes. Rewritten to boot a
      whole topological LEVEL at once. Two-step finding (test/bench_bringup.ae,
      real /bin/sleep boots, N independent nodes):
        - Naive fix (fan out Boot to an actor per node, then await) is NO better
          than serial — the Aether actor runtime SERIALIZES blocking ops inside
          actors, so a per-actor health poll can't overlap. Structural
          parallelism alone is useless here. (Worth reporting upstream.)
        - Real fix: the DETACHED single-poller. Every driver already backgrounds
          its boot (bwrap/podman/firecracker/systemd-run); the actor's Boot now
          does ONLY driver_up (no blocking poll), and a SINGLE engine poller
          (_await_level) probes the whole level, promoting each node to UP as its
          health passes. Boots overlap at the OS level → wall-clock ~= slowest
          boot. Measured ~4.6× at width 32 (macOS, 8 cores), scaling with width.
      depends() ordering preserved (a node dispatches only once its dep is UP);
      per-node health windows honoured (level budget = max node window; tick =
      fastest node interval). Removed the per-actor _poll_to_up / _await.
      VALIDATION: compiles; principle proven by the benchmark. The change is to
      the CORE bring-up path — LIVE-PROVE on Bazzite (a multi-node `aeo up`, e.g.
      silly_addition_containers) before trusting it.
      - [x] BATCHED liveness (2026-07-01): the per-level poller now checks all
            pidfile-kind, health-less nodes (bwrap/firecracker/kvm — readiness ==
            "process alive") in ONE shell sweep per tick instead of N×(cat+kill).
            Uses `read`/`kill -0` builtins → zero child spawns; collapses 2N Aether
            run_captures into 1. Measured 14.6× cheaper per tick at width 32
            (macOS); the sweep's correctness (live/dead/missing pids) validated
            directly. Health-checked / non-pidfile nodes keep the identical
            per-node probe (zero behaviour change). In _await_level /
            _batch_pidfile_alive.
      - [x] VM levels parallelize (2026-07-01): `_up_kvm` already returns fast
            (qemu launches detached) and probe() gates kvm readiness on the guest
            agent's /health — so KVM VMs ALREADY boot concurrently under the new
            engine (no change needed). `bhyve_up` used to block on _wait_guest_ready;
            it now RETURNS after `vm start` when the agent path is on (readiness
            gated by the poller's agent /health probe, which is IP-independent),
            so sibling bhyve VMs boot concurrently. Legacy (no-agent) bhyve still
            blocks — probe can't confirm ssh-reachability without the guest IP.
      - [x] container/docker liveness batched too (2026-07-01): health-less
            container/docker nodes are checked with one rootless `podman/docker ps`
            per tick (driver_linux.running_names), same reliable-source rule as the
            pidfile sweep. nspawn/lxc are DELIBERATELY left per-node: their liveness
            is sudo-gated (machinectl/lxc-ls), and a false "down" from a denied sudo
            in a batch would HANG bring-up — the per-node probe is the safe path.
            All batching is a fast-path gated by _batchable(); health-checked and
            non-batchable nodes are byte-for-byte unchanged.

- [x] **Aether DURATION LITERALS woven into the aeo DSL** (Paul 2026-06-27) —
      DONE. The FluentSelenium within()/secs() idiom: `within(30s) every(500ms)`
      expresses a health retry as WALL-CLOCK time, not a hand-computed attempt
      count; get_budget DERIVES attempts = window/interval. _dur_ms(d) = d/1000000
      (Duration is i64 ns; `as int` rejected, `/` works). Back-compat: explicit
      health_budget wins; int setters untouched. LIVE on Bazzite. spec_duration 4.
      (Aether has no fn overloading — so `within`/`every` are NEW names, not
      Duration overloads of health_interval.)
      - [ ] Follow-up: an egress(target, port, timeout: Duration) connect-window,
            and any other ms-int site that wants a duration form.

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
- [x] **`driver_wslc` — a Windows Linux-container tier via WSL Containers** — DONE
      (2026-07-03, commit `2615bbb`). `lib/driver_wslc` shells Microsoft's native
      `wslc.exe` directly (no podman, no distro prefix). Wired into compose (`wslc`
      kind) + runner (up/exec/down/probe); unit spec 6/6; example present. Got wslc
      onto the guest by upgrading WSL 2.7.10 → 2.9.3 (`wsl --update --pre-release` —
      NO Store needed, so the unlicensed-guest block didn't bite; nested virt NOT
      required despite the old warning). LIVE-PROVEN vs real `wslc.exe` 2.9.3.0: the
      driver's exact argv ran the full round-trip (run -d -p → list json Name-match
      + port bound → exec hostname → container stop → container remove → list []).
      Handled wslc's deltas from podman: `container remove` not `rm`, no `--replace`
      (manual idempotency), `list --format json` not Go templates (probe matches the
      "Name" field). STILL OPEN (follow-ups, not the driver itself): render
      limit{}/constrain{} onto wslc's governance knobs (caps/network-deny/registry
      allowlist ↔ attest); and the headless WSL container API (NuGet
      `Microsoft.WSL.Containers`) as an alternative to shelling the CLI.
      --- original rationale (kept for the follow-ups) ---
      Native OCI Linux
      containers on Win11 with NO Docker Desktop, via a dedicated optimized Hyper-V
      VM. Directly relevant because:
        - **New driver tier**: `wslc` syntax mirrors Docker (`wslc run -p 8080:80
          nginx`, `wslc build -t app .`, `wslc container ps`), so a `driver_wslc`
          is close to `driver_linux` with the engine swapped — the run/build/probe/
          down argv shape carries over. It's the WINDOWS analog of the podman
          container tier (a real Linux-container backend that isn't Linux-hosted).
        - **Developer API for headless launch** — native Windows apps can start +
          manage containers with no terminal (MS demoed a .exe silently running a
          Linux container). That's the seam a Windows-resident aeo-agent would use
          to run nested children WITHOUT bundling podman — the aeo-agent-on-Windows
          blocker above (agent Linux-bound) is partly answered: the *agent* still
          needs a Windows arm, but the *child-run* mechanism exists natively.
        - **Enterprise governance maps onto aeo's grammar** — registry allow/block
          lists, resource audit, host file/net/clipboard governance are exactly
          aeo's `attest()` (registry pin) + `limit{}`/`constrain{}` (resource/net)
          + audit-trail axes. A `driver_wslc` should render the SAME limit/constrain
          vocabulary onto wslc's governance knobs (substrate-portable, like the
          FreeBSD↔Linux confinement peers).
      Blockers/unknowns: it's PREVIEW (single-container only, no Compose — fine,
      aeo owns orchestration; sparse docs; rough edges). Spike: does `wslc` expose
      per-container resource caps + network-deny that map to constrain{}? Confirm
      the headless API is scriptable from an Aether-built binary. Sequencing: after
      the Windows agent arm exists (the two are complementary — agent = control
      plane, wslc = the container runtime it drives).

      GROUND-TRUTH from the real Win11 guest on the box (winbaz, build 26200,
      "Windows 10 Home" name-string, 2026-07-02): the container primitives are
      present-but-OFF — `Microsoft-Windows-Subsystem-Linux` DISABLED,
      `VirtualMachinePlatform` DISABLED, `HypervisorPlatform` (WHP — the
      microsandbox/microVM base) DISABLED, `wsl.exe` launcher exists but WSL "is
      not installed", `wslc.exe` NOT FOUND. So:
        - **A `driver_wslc` (and any WSL/WHP tier) must ENABLE the feature first** —
          `dism`/`Enable-WindowsOptionalFeature -Online -FeatureName ...` (+ likely
          a reboot) is a prerequisite step, the Windows analog of "the seed installs
          podman." The TODO's "does wslc expose caps" spike is downstream of that.
        - **`wslc` isn't on this build yet** (26200) — the launchers ship before the
          feature. So Paul's instinct ("watch Windows updates for new container
          possibilities") is the right cadence: these are nascent, toggle-able
          isolation primitives that arrive incrementally. Re-probe after WSL is
          enabled + Windows updates land; when `wslc` appears, THEN spike the
          caps↔constrain mapping on a real container.
        - **Home-edition caveat**: WSL works on Home; the newer WSL Containers'
          Home-vs-Pro gating is the open question — verify on THIS Home guest before
          assuming consumer-Windows reach.
      ENABLE ATTEMPT (2026-07-02, over SSH — no walking to the box):
        - Enabled `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`
          via `Enable-WindowsOptionalFeature` (admin-over-SSH worked, no elevation
          block) → both `Enabled`, `RestartNeeded=True`; rebooted the guest (came
          back on :22, key-auth survived). Guest has internet egress (virbr0 NAT).
        - BUT `wsl --install` (and `--web-download`) DON'T WORK: the inbox
          `wsl.exe` in System32 is an OLD STUB that doesn't implement the modern
          `--install`/`--web-download` flags — it just prints "WSL is not installed,
          run wsl --install" regardless of args. The real WSL is a STORE-delivered
          appx, and **this guest is UNLICENSED (skip-license test install) so the
          Microsoft Store doesn't function** → the app never delivers.
        - So a `driver_wslc`/WSL provisioning path on an unlicensed or Store-less
          Windows must **sideload the WSL `.msixbundle` from GitHub**
          (`github.com/microsoft/WSL/releases`) + `Add-AppxPackage` — the
          Store-free install. (In progress on the guest.) This is a REAL extra step
          the driver must own beyond "enable the feature."
        - **And nested-virt**: WSL2 boots a lightweight VM, but win11 is itself a
          KVM guest — WSL2 needs the Bazzite host's KVM to expose nested virt to the
          win11 domain (`kvm_amd nested=1` + host-passthrough CPU in the libvirt
          XML). If a distro fails to boot post-install with a hypervisor error,
          that's why. WSL1 needs no nested-virt (a fallback).
      NET: on Windows, the container-tier prerequisites are a real chain —
      enable-feature + reboot → (Store OR sideload-MSIX) the WSL app → nested-virt
      for WSL2 → THEN a distro + a container runtime. A `driver_windows` child-run
      arm has to automate this chain; it's meatier than the Linux "seed installs
      podman" step. Documented from the real guest, not a news article.
      RESULT (2026-07-02): **WSL2 INSTALLED** on the unlicensed guest via GitHub
      MSIX sideload — `Add-AppxPackage Microsoft.WSL_2.7.10.0_x64_ARM64.msixbundle`
      (~518MB; the crux was a clean single-writer re-download — the first tries
      were truncated → 0x80073CF0). `wsl --version` → 2.7.10.0, Linux kernel
      6.18.33.2, WSLg 1.0.73.2. So the Store-free WSL install path WORKS on an
      unlicensed Windows — a real, reusable finding for a `driver_windows` provisioner.
      **NESTED VIRT PROVEN + WSL2 DISTRO BOOTED (2026-07-02):** the Bazzite host
      already had `kvm_amd nested=1` and the win11 libvirt domain already had
      `<cpu mode='host-passthrough'>` — no changes needed. `wsl --install -d Ubuntu`
      pulled Ubuntu 26.04 cleanly (WSL 2.7.10 fetches distros from its own source —
      NO Store-sideload needed for the distro, unlike the WSL app itself), VERSION 2.
      `wsl -d Ubuntu -- uname -a` → `Linux winbaz 6.18.33.2-microsoft-standard-WSL2
      ... x86_64` (RC=0). A REAL Linux kernel runs in a WSL2 VM, inside the win11
      KVM guest, inside the Bazzite host — a 3-deep virt stack, all over SSH.
      SO: a Windows guest now has a live Linux container-capable environment. The
      remaining piece for blocker #1 (the Windows child-run mechanism) is podman
      INSIDE this WSL2 Ubuntu (apt install podman → run OCI containers), which the
      driver_windows arm would drive via `wsl -d Ubuntu -- podman ...`. That's the
      concrete, now-testable path to a functional Windows aeo-agent.
      **PODMAN-IN-WSL2 PROVEN (2026-07-02):** `apt install podman` in the WSL2
      Ubuntu (podman 5.7.0), then `wsl -d Ubuntu -u root -- podman run --rm
      debian:stable-slim echo ...` PULLED debian from Docker Hub and RAN the
      container (no cgroup/systemd errors — podman 5.7 handles WSL2 cleanly).
      WSL2 egress works (deep NAT: WSL2→Windows→virbr0→internet; apt Hits all
      Ubuntu repos). So the FULL Windows child-run substrate is proven end-to-end:
        Bazzite(KVM host) → win11 KVM guest → WSL2 Ubuntu → podman container.
      Blocker #1's mechanism is SOLVED — a driver_windows arm runs children via
      `wsl -d Ubuntu -- podman run ...`, mirroring the Linux agent's
      _ensure_child_container. What's left for a functional Windows agent is the
      AGENT-SIDE wiring: build the agent .exe for Windows (mingw, libaether.a-for-
      mingw pending) + a driver_windows body that shells `wsl ... podman` instead
      of native podman. The hard substrate gates are all cleared.
- [ ] aether#870/#878 are CLOSED (fixed in ae 0.326). BUT investigated
      2026-06-27: they do NOT let the aeocha specs drop their bare `import
      std.string`. #878 fixes the QUALIFIED surface (`string.copy()` with the dot)
      on any import; #870 fixes a selective ENTRY-FILE import suppressing merged
      qualified calls. The aeocha workaround is for aeocha's inlined code calling
      `copy` BARE/UNQUALIFIED — which needs a bare `import std.string` to provide
      the bare-name binding, and that's aeocha's design, NOT what #870/#878 fixed.
      So the ~14 bare-import sites STAY unless aeocha switches to qualified
      `string.copy()` internally (an aeocha change), or ae adds bare-name
      re-export. Couldn't even test on this box: installed ae is 0.325 (the 0.326
      source has the sib's uncommitted WIP + a version-stamp quirk; didn't force a
      build). Revisit when ae 0.326+ is cleanly installed.
- [ ] aether#929/#586/#744 CLOSED (narrowing/Duration/module-global soundness).
      aeo not exposed today (no module-scope `var` 64-bit cells; durations convert
      ns->ms-int immediately). Commented on #929 with the corroborating near-miss.
- [ ] **aether#937 (module `var` not persisted across import) FIXED in ae 0.328**
      — verified read-back=7 (was 0). aeo was immune anyway (zero module vars; all
      ambient state via std.config — kept as a design rule + memory). With #934
      (0.327) + #937 (0.328) BOTH fixed, the full fluent-facade shape now builds +
      runs end-to-end: verified `matchers.expect_int(5).to_equal(5).to_be_gt(0)`
      across the import boundary with an ambient cur_fw cell ([myspec] ok lines).
- [ ] **NOW UNBLOCKED: fluent aeocha facade + aeo spec sweep.** #934+#937 fixed,
      so aeocha can ship `expect_int(x).to_equal(5).to_be_gt(0)` (chainable matchers
      + an ambient fw cell). That's an AEOCHA change; THEN a mechanical aeo sweep
      of ~18 specs from `aeocha.assert_str_eq(fw, got, want, msg)` to the fluent
      form. Real readability win, now actionable.
- [ ] **aether#934 (cross-module UFCS) FIXED in ae 0.327** — verified end-to-end:
      `b.bump()` AND `b.bump().bump()` resolve + run across the import boundary
      (was the exact failure we commented on). Unblocks a FLUENT aeocha facade
      (`expect_int(x).to_equal(5).to_be_gt(0)`) — which would replace aeo's verbose
      `aeocha.assert_str_eq(fw, got, want, msg)` across ~18 specs. That's an AEOCHA
      change (add the chainable facade), then a mechanical aeo spec sweep. aeo's
      OWN DSL is block-setter (container("db"){within(30s)}), not method-chain, so
      not directly blocked — but the readability win on the specs is real.
      (Compiler bump to 0.327: full aeo suite + demos re-checked, no regression.)
