# bhyve guest networking on AMD Ryzen: the full journey

A post-mortem of getting a Linux guest networked under bhyve on the
GhostBSD box, written for posterity. We chased *networking* symptoms for a
long time before discovering the real cause was a **guest boot hang**.
Several of the workarounds below stack on top of each other to route around
problems; **once the root cause (the AMD boot hang) is properly fixed, most
of them can be removed.** This doc says which.

**Box:** GhostBSD / FreeBSD 15.0-RELEASE-p2, **AMD Ryzen 7 5800U** (Zen 3),
ZFS root, wired NIC `re0` (192.168.0.57). vm-bhyve 1.7.3,
edk2-bhyve-g202508, dnsmasq 2.92, qemu 11.0.0, fuse-ext2.

---

## TL;DR — the layers, and what's removable

| # | Workaround (file) | Solves | Removable when… |
|---|---|---|---|
| 1 | cloud-init `datasource_list:[NoCloud,None]` | ~160s init stall | keep (cheap, always good) |
| 2 | NAT switch + dnsmasq + pf (`setup-nat.sh`) | LAN switch eating bridged DHCP replies | maybe, if the LAN/switch is fixed → could go back to bridged |
| 3 | AMD GRUB params (`patch-amd-image.sh`) | **AMD Ryzen boot hang** (the real cause) | **never remove** until a better bhyve/firmware fix exists |
| 4 | static guest IP on the seed | dnsmasq not seeing DHCP broadcasts on the bridge | if the bridge-broadcast issue is solved → back to DHCP |
| 5 | golden image + clone (`setup-base.sh`) | slow ~3min provisions | keep (it's a speed feature, not a workaround) |

**The single highest-value finding:** the guest mostly **wasn't booting**.
All the "no DHCP / tap out=0" was downstream of an intermittent AMD Ryzen
early-boot hang. Fix the boot and #2 and #4 may become unnecessary.

---

## The journey, in order

### Phase 1 — "the guest boots but never networks" (bridged)
Symptom: `tap0 in=0 out=0`, no ARP, no lease, for every distro.
- **Found:** Ubuntu's netplan rendered `eth0` but left it state **DOWN**
  (verified at the console: `ip -br addr` → `eth0 DOWN`; a manual
  `ip link set eth0 up; dhclient eth0` instantly got a lease).
- **Workaround:** cloud-init `bootcmd`/`runcmd` to force the link up + DHCP.
- **Also found:** Ubuntu first boot is just slow (~160s) and cloud-init
  stalls ~160s probing EC2 metadata unless pinned →
  `datasource_list:[NoCloud,None]` (#1, keep it).
- This got us **one full convergence** (container in the VM, curled from
  the host). We thought networking was solved. It wasn't — that was a lucky
  clean boot.

### Phase 2 — "it's non-deterministic" (bridged, intermittent)
Symptom: the same config networked some boots, not others. Then a sharper
clue with tcpdump access:
- **`netstat -I tap0 -b` → `in=6162 out=0`** — the guest SENDS thousands of
  packets, but ZERO come back to its tap.
- Bridge config was correct: `re0` PROMISC, both members LEARNING, pfil
  off. Disabling re0 offloads (`-rxcsum -txcsum -tso -lro`) did **not** help.
- **Conclusion at the time:** bridged L2 to the LAN is eating the DHCP
  reply — looked like an **upstream LAN switch** limiting MACs per port
  (a 2nd MAC on the host's port gets dropped → intermittent). Persisted
  across a host reboot (ruled out stale host state).
- **Workaround → NAT mode (#2, `setup-nat.sh`):** put the guest on a
  private net (172.16.0.0/24) behind the host with a LOCAL dnsmasq, host
  NATs out. The guest's DHCP never touches the LAN switch.
  - vm-bhyve's *internal* NAT is disabled on FreeBSD (it warns) — so
    `setup-nat.sh` does it manually: `pkg install dnsmasq`;
    `sysctl net.inet.ip.forwarding=1` + `gateway_enable`; `/etc/pf.conf`
    `nat on re0 from 172.16.0.0/24 -> (re0)` + `pf_enable`; dnsmasq on
    `vm-aeonat`; `vm switch create/address/nat aeonat` + a `linux-nat`
    template.

### Phase 3 — "even NAT doesn't network" → the real cause
On NAT the guest sent **almost nothing** (`tap in=16` in minutes, vs 6000+
on the LAN). That asymmetry was the giveaway:
- The bhyve process ran for minutes but the guest emitted ~16 packets and
  CPU/packet activity barely advanced. **The guest was hung very early in
  boot**, not failing to network. Every prior "no DHCP" was downstream of
  this. The intermittency: it boots fully only *occasionally*.
- CPU: **AMD Ryzen 7 5800U**. Two web searches ("bhyve AMD Ubuntu hang")
  agreed: AMD **TSC/clocksource** handling in virtualization + bhyve not
  persisting UEFI vars → early-boot freeze.
- **Fix → AMD GRUB params (#3, `patch-amd-image.sh`):**
  `clocksource=hpet tsc=unstable processor.max_cstate=5 idle=halt`.
  These must be on the cmdline from the FIRST boot — cloud-init can only fix
  the NEXT boot (chicken/egg) — so we patch the image's GRUB **offline** on
  the host: `qemu-img` qcow2→raw, `mdconfig -a`, `gpart show` (p1 =
  linux-data ext4 root), `fuse-ext2 -o rw+`, `sed` the params into BOTH
  `/etc/default/grub` and the live `/boot/grub/grub.cfg`, repackage →
  `jammy-amd.img`.
- **Result:** with the patched image the guest boots **further** — it
  reached Linux networking and sent repeated `BOOTP/DHCP Request`s (seen via
  tcpdump). Big progress. But the hang is still **intermittent** — many
  boots still freeze at ~18-20 packets.

### Phase 4 — "the patched guest sends DHCP but gets no lease"
On the boots that DID progress:
- tcpdump on `vm-aeonat` showed the guest's `DHCP Request` every ~65s, for
  minutes — guest alive and trying.
- **But dnsmasq's log showed it received NOTHING.** The broadcast is on the
  bridge (tcpdump sees it) but never reaches dnsmasq's socket on the same
  bridge — a FreeBSD `if_bridge` broadcast-to-host-stack quirk.
- **Tried (none worked):** removing `bind-interfaces`; `bind-dynamic`;
  `dhcp-authoritative`. dnsmasq still logged zero DHCP.
- **Workaround → static guest IP (#4):** skip DHCP entirely. cloud-init
  network-config with `addresses:[172.16.0.50/24]`,
  `gateway4:172.16.0.1`. vm-bhyve's `vm create -n <netconfig>` is supposed
  to take it but writes its own DHCP block, so set it on the seed AFTER
  create then rebuild the CIDATA iso:
  ```sh
  NC=/zroot/vm/<name>/.cloud-init/network-config
  sudo sed -i '' -e 's|dhcp4: true|addresses: [172.16.0.50/24]\n    gateway4: 172.16.0.1\n    nameservers: {addresses: [172.16.0.1]}|' \
                 -e '/dhcp6: true/d' -e '/accept-ra: true/d' "$NC"
  sudo makefs -t cd9660 -o rockridge -o label=CIDATA /zroot/vm/<name>/seed.iso /zroot/vm/<name>/.cloud-init
  ```
- The static config is correct and would make a booted guest instantly
  reachable — but it **can't help a guest that doesn't boot**, and the
  intermittent hang (Phase 3) still bites most boots.

### Phase 5 — SOLVED (console proof corrected Phases 3-4)
A console capture (by a person — remote cu/nmdm capture doesn't work)
revealed **the "boot hang" was a MISDIAGNOSIS**. The AMD-patched guest
*boots fully* to `login:` in ~126s; the low tap-packet count I read as
"hung" was a HEALTHY guest stuck at `systemd Wait for Network` because it
had **no IPv4**. The console showed why:
```
cloud-config failed schema validation!
ci-info: | eth0 | True | fe80::5a9c:fcff:fe0f:dbfb/64 | ... |   <- link-local only, no IPv4
```
**Root cause of the no-network:** my `sed`-edits to the cloud-init seed's
network-config produced **schema-INVALID YAML**, so cloud-init rejected it →
no IPv4 → wait-online hangs. (The MAC matched fine — that was a red herring.)

**THE FIX (test/patch-static-ip.sh):** write a CLEAN, valid netplan
*directly into the guest disk* (mount disk0.img via fuse-ext2), NOT by
sed-editing the seed: `/etc/netplan/99-aeo-static.yaml` with a static
address + `cloud.cfg.d/99-disable-network.cfg: network:{config:disabled}`.
Boot → `eth0 UP 172.16.0.50/24`, pings + ssh in seconds.

**Convergence re-proven on this reliable path:**
`host -> curl http://172.16.0.50:8080/add/2/3 = 5` (the /add service in the
guest, curled from the FreeBSD host, deterministic — no DHCP, no boot
flakiness).

### Still open (smaller)
- **NAT egress:** the guest reaches the host (ssh to 192.168.0.57 works) but
  not the internet — pf NATs outbound (tcpdump re0 shows `192.168.0.57 >
  8.8.8.8` + replies) but the reverse-NAT'd reply doesn't return to the
  guest on vm-aeonat. So in-guest apt/pull fails. Workaround: STAGE
  artifacts from the host (build the image on a machine with podman ->
  `podman save` tar -> scp into the guest -> `podman load`). Fix the pf
  reverse path later.
- **podman in the guest:** the bare patched image has none; the golden base
  (aeo-base) has podman baked in — clone it + patch-static-ip + load a
  staged image.

### Removability update (post-solve)
- #3 AMD GRUB params — KEEP (the boot genuinely needs them; the boot is NOT
  unreliable once patched, contrary to the earlier scare).
- #4 static IP — now the PRIMARY networking method (clean netplan in-disk);
  reliable. Could revert to DHCP only if the bridge-broadcast issue is
  solved, but static works and is simpler.
- #2 NAT — outbound translation works; the reverse path needs a fix for full
  egress, but the convergence doesn't need egress (stage artifacts).

---

## Things we tried that did NOT help (so nobody re-tries them)
- Disabling re0 hardware offloads (`-rxcsum -txcsum -tso -lro`) — bridged
  reply still lost.
- A host reboot — networking still non-deterministic afterward (ruled out
  stale tap/bridge/nmdm state as the cause).
- dnsmasq `bind-interfaces` off / `bind-dynamic` / `dhcp-authoritative` —
  dnsmasq still never saw the guest's DHCP broadcast on the bridge.
- Identity-reset golden clones (clear machine-id + cloud-init) — made clones
  FLAP (lease appears then drops); the no-reset "warm copy" model is better.
- Bumping the guest to 2 vCPU / 2G — didn't fix the boot hang (helps once it
  boots, doesn't prevent the hang).

## If you're picking this up later — likely cleanups
- **Fix the boot hang properly** (newer bhyve/edk2, a CPU/APIC flag like a
  `bhyve_options` tweak, or a kernel cmdline like `acpi=off`/`nomodeset`
  found by console-watching a hung boot). Then:
  - #4 static IP may be droppable → back to DHCP, IF the bridge-broadcast
    issue (Phase 4) is also solved (try dnsmasq alternatives, or a different
    DHCP server like ISC dhcpd which may handle FreeBSD bridges better).
  - #2 NAT could revert to bridged IF the upstream LAN switch is the
    culprit and gets fixed/replaced — but NAT is arguably nicer anyway
    (isolation, no LAN pollution), so maybe keep it.
- **Keep #1 (datasource pin), #3 (AMD params), #5 (golden clone)** — these
  are good regardless.

See also `docs/bsd-host-setup.md` (the reproducible setup) and memory
`bhyve-guest-networking` (running diagnosis notes).
