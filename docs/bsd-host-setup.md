# GhostBSD/FreeBSD host setup for aeo (bhyve substrate)

Everything needed to turn a fresh GhostBSD/FreeBSD 15 box into an aeo bhyve
host. This is the authoritative env-setup record — keep it current as the
setup evolves.

Box: `paul@192.168.0.57` — GhostBSD on **FreeBSD 15.0-RELEASE-p2**,
**AMD Ryzen 7 5800U** (Zen 3), ZFS root (`zroot`), wired NIC `re0`
(192.168.0.57), `wlan0` no-carrier.

Versions in use: bhyve from base (15.0), `vm-bhyve 1.7.3`,
`edk2-bhyve-g202508` (UEFI firmware), `dnsmasq 2.92`, `qemu 11.0.0`
(qemu-img), `fuse-ext2 0.0.11`.

---

## 1. Packages

```sh
pkg install -y vm-bhyve bhyve-firmware qemu-tools dnsmasq fusefs-ext2
```
- **vm-bhyve** — VM manager. **bhyve-firmware** — UEFI ROM (BHYVE_UEFI.fd).
- **qemu-tools** — `qemu-img` (vm-bhyve converts qcow2 cloud images → raw;
  also used to convert the AMD-patched image, §5).
- **dnsmasq** — local DHCP/DNS for the NAT network (§4).
- **fusefs-ext2** — mount the Linux cloud image's ext4 offline to patch
  GRUB (§5).

## 2. Kernel module + vm-bhyve init

```sh
kldload vmm
sysrc -f /boot/loader.conf vmm_load="YES"          # persist vmm
sysrc vm_enable="YES" vm_dir="zfs:zroot/vm"
zfs create zroot/vm 2>/dev/null || true
zfs set mountpoint=/zroot/vm zroot/vm
vm init
cp /usr/local/share/examples/vm-bhyve/* /zroot/vm/.templates/
```

## 3. sudo (passwordless for the aeo automation user)

`/usr/local/etc/sudoers.d/aeo` — the agent drives the box over ssh with
NOPASSWD sudo, scoped to the tools it needs:

```
paul ALL=(ALL) NOPASSWD: /usr/local/sbin/vm, /usr/sbin/jail, /usr/sbin/jexec, /usr/sbin/jls, /sbin/ifconfig, /sbin/zfs, /sbin/zpool
paul ALL=(ALL) NOPASSWD: /usr/bin/cu, /usr/sbin/kldload
paul ALL=(ALL) NOPASSWD: /sbin/pfctl, /usr/sbin/tcpdump, /usr/sbin/service, /usr/sbin/sysctl
paul ALL=(ALL) NOPASSWD: /usr/bin/tee, /bin/mkdir
paul ALL=(ALL) NOPASSWD: /usr/bin/sed
paul ALL=(ALL) NOPASSWD: /sbin/mdconfig, /sbin/mount, /sbin/umount, /usr/local/bin/fuse-ext2, /sbin/gpart, /usr/local/bin/qemu-img
```
(tcpdump/pfctl/sysctl = NAT + diagnosis; sed/mdconfig/mount/fuse-ext2/
qemu-img/gpart = offline image patching §5. **pfctl is `/sbin/pfctl`** on
FreeBSD 15 — NOT `/usr/sbin/pfctl`; a path mismatch makes `sudo -n pfctl` fail.
tee + mkdir let `aeo up` write + load each VM's `/etc/pf.anchors/aeo-<vm>` —
the netpolicy enforcement seam. **VERIFIED on the box 2026-06-25: write→load→
read-back of a resolved deny-default ruleset round-trips through real pfctl.**)

## 4. Networking — NAT mode (REQUIRED on this box)

Bridged-to-LAN networking is unreliable here: bridged guests send DHCP but
get **no reply back to the tap** (`netstat -I tap0 -b` → in=6000+, out=0) —
the upstream LAN switch appears to limit MACs per port. NAT sidesteps L2 to
the LAN entirely (guest on a private net behind the host, host NATs out).

Run the one-time setup:
```sh
sudo sh test/setup-nat.sh
```
which does: install dnsmasq; `sysctl net.inet.ip.forwarding=1` +
`sysrc gateway_enable=YES`; `/etc/pf.conf` source-NAT
`nat on re0 from 172.16.0.0/24 -> (re0)` + `sysrc pf_enable=YES` +
`service pf restart`; `/usr/local/etc/dnsmasq.conf`
(`interface=vm-aeonat`, `dhcp-range=172.16.0.10,172.16.0.250`) +
`service dnsmasq restart`; `vm switch create aeonat` +
`vm switch address aeonat 172.16.0.1/24` + a `linux-nat` template on that
switch. Guests then get a `172.16.0.x` lease from LOCAL dnsmasq (never
touches the LAN switch). `sudo sh test/setup-nat.sh --check` shows state.

Note: vm-bhyve's *internal* NAT is disabled on FreeBSD — it warns and
expects pf + dnsmasq done manually, which setup-nat.sh does.

### Per-VM pf anchor (the netpolicy enforcement seam — REQUIRED for confinement)

`aeo up` LOADS each VM's deny-default netpolicy (from `constrain{ egress /
ingress_from / deny_egress }`) into a per-VM pf anchor `aeo/<vm>` (lib/pf —
`pfctl -a aeo/<vm> -f /etc/pf.anchors/aeo-<vm>`). The write→load→read-back chain
is VERIFIED against real pfctl on this box (2026-06-25). But two pf.conf changes
are REQUIRED for the loaded rules to actually govern traffic:

1. **Reference the anchor** — add `anchor "aeo/*"` to `/etc/pf.conf`.
2. **Don't let a blanket pass override it.** The default `setup-nat.sh` pf.conf
   ships `pass quick on vm-aeonat all` + `pass all`. The `quick` inter-VM pass
   short-circuits — it passes ALL VM↔VM traffic BEFORE the anchor is consulted,
   so confinement never engages. And the trailing non-quick `pass all` re-allows
   whatever an anchor `block`ed (pf is last-match-wins). **Remove the blanket
   `pass quick on vm-aeonat all`** and keep only the host-control-plane passes
   (DHCP/DNS to 172.16.0.1, host→guest ssh), so un-whitelisted inter-VM flows
   fall through to each VM's anchor deny.

⚠️ Editing live pf.conf can interrupt running guests' connectivity — parse-check
first (`sudo pfctl -nf /etc/pf.conf.new`), apply when no deploy is mid-flight,
and the host's own LAN reachability (192.168.0.57 on re0) is unaffected since the
changes are scoped to the vm-aeonat switch.

Without these, `aeo up` writes + loads the anchor (and logs success), but pf
never enforces it — the deny-default policy is silently inert. With them, a
compromised node can only reach the peers/ports its `constrain{}` block
whitelisted; everything else (incl. egress for a `deny_egress` node) is blocked.
`aeo down` flushes the anchor (`pfctl -a aeo/<vm> -F rules`) so a torn-down VM
leaves no stale deny rules on its (now-reused) address.

The `pfctl` calls go through `sudo -n` (the NOPASSWD pfctl in the sudoers above).

### Resource caps (rctl — the exhaustion-DoS defense, the `limit{}` block)

`aeo up` applies each node's `limit{ limit_mem/limit_cpu/limit_maxproc/... }`
caps via FreeBSD `rctl` (lib/rctl), so a malicious or runaway node can't STARVE
the host (fork bomb, memory balloon, fd gluttony) — rctl DENIES the offending op
rather than leaving it to OOM roulette. Two host prerequisites:

1. **Enable RACCT/RCTL** — it's a boot tunable (not runtime-settable), but RACCT
   IS compiled into GENERIC. Add to `/boot/loader.conf` and REBOOT:
   ```
   kern.racct.enable=1
   ```
   (Verify after reboot: `sysctl kern.racct.enable` → `1`.)
2. **Grant rctl** in the sudoers drop-in: add `/usr/bin/rctl` to a NOPASSWD line
   (rctl is `/usr/bin/rctl` on FreeBSD 15).

⚠️ Enabling RACCT needs a REBOOT — do it during a maintenance window, not with
guests mid-deploy. Until both are done, `aeo up` records + logs the caps but
they aren't enforced (an `rctl: RACCT disabled` error, surfaced as a non-fatal
"caps NOT enforced" line — the node still comes up).

v0 caps **jail** nodes (`jail:<name>` subject); bhyve-VM nodes (a hypervisor
process) are a later thickening (PID targeting) — aeo says so loudly rather than
silently skipping. `aeo down` removes the node's rules (`rctl -r jail:<name>`).

## 5. AMD Ryzen guest-boot fix (REQUIRED — patched image)

Ubuntu Linux guests hang very early in boot under bhyve on this AMD Ryzen
box, intermittently — the guest barely transmits (~20 packets in minutes)
and never reaches networking. Root cause: AMD **TSC/clocksource** handling
in virtualization + bhyve not persisting UEFI vars. Fix = AMD-safe kernel
cmdline, baked into the image's GRUB **offline** (it must be on the cmdline
from the FIRST boot; cloud-init can only fix the NEXT boot — chicken/egg).

Build the patched image once (host-side, no guest boot needed):
```sh
sudo sh test/patch-amd-image.sh      # qcow2 -> raw, md-attach, fuse-ext2
                                     # mount, inject GRUB params, repackage
```
which injects `clocksource=hpet tsc=unstable processor.max_cstate=5
idle=halt console=ttyS0` into BOTH `/etc/default/grub` and the live
`/boot/grub/grub.cfg` kernel lines, producing `jammy-amd.img`. The driver
provisions from `jammy-amd.img` (the AMD-safe image) instead of the stock
cloud image.

Manual steps it runs (for reference / debugging):
```sh
qemu-img convert -f qcow2 -O raw jammy-server-cloudimg-amd64.img jammy-patched.raw
MD=$(mdconfig -a -t vnode -f jammy-patched.raw)     # -> md0
gpart show $MD                                       # p1 = linux-data (ext4 root)
fuse-ext2 /dev/${MD}p1 /tmp/jammy -o rw+
sed -i '' 's/console=tty1 console=ttyS0/& clocksource=hpet tsc=unstable processor.max_cstate=5 idle=halt/g' /tmp/jammy/boot/grub/grub.cfg
# (+ /etc/default/grub for future update-grub)
sync; umount /tmp/jammy; mdconfig -d -u $MD
qemu-img convert -f raw -O qcow2 jammy-patched.raw jammy-amd.img
```

## 5b. Static guest IP (bypass DHCP-broadcast issue)

Even with the AMD-patched image (guest boots, sends DHCP), dnsmasq on the
NAT bridge does NOT receive the guest's DHCP broadcasts — they're visible
on `vm-aeonat` via tcpdump but never reach dnsmasq's socket (a FreeBSD
if_bridge broadcast-to-host-stack quirk; tried `bind-interfaces` off,
`bind-dynamic`, `dhcp-authoritative` — none worked). So the guest never
gets a lease.

Workaround: give the guest a **static IP** via cloud-init network-config,
skipping DHCP entirely. vm-bhyve's `vm create -n <netconfig>` is supposed to
take it but writes its own DHCP block instead — so set it on the seed AFTER
create:
```sh
NC=/zroot/vm/<name>/.cloud-init/network-config
sudo sed -i '' -e 's|dhcp4: true|addresses: [172.16.0.50/24]\n    gateway4: 172.16.0.1\n    nameservers: {addresses: [172.16.0.1]}|' \
               -e '/dhcp6: true/d' -e '/accept-ra: true/d' "$NC"
# rebuild the cloud-init seed (vm-bhyve uses makefs cd9660 label=CIDATA):
sudo makefs -t cd9660 -o rockridge -o label=CIDATA /zroot/vm/<name>/seed.iso /zroot/vm/<name>/.cloud-init
sudo vm start <name>
# guest comes up at 172.16.0.50; host reaches it directly (ssh/curl).
```
Each guest gets a distinct static IP (.50, .51, …). The host NATs them out
via the pf rule.

## 6. Verify

```sh
sudo sh test/setup-nat.sh --check                    # NAT up
# provision a guest from jammy-amd.img on the aeonat switch, watch:
#   netstat -I <tap> -b   -> Ipkts climbs into the thousands (booting)
#   cat /var/db/dnsmasq.leases  -> a 172.16.0.x lease appears
#   ssh ubuntu@<lease> 'cat /proc/cmdline'  -> shows clocksource=hpet ...
```

See also `docs/bhyve-networking-journey.md` (the full journey — every
approach tried, why each helped/failed, and which workarounds become
removable once the AMD boot hang is fixed), memory `bhyve-guest-networking`
(the running diagnosis trail), and `docs/aeo-agent.md`.
