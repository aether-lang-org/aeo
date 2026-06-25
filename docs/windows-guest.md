# Windows 11 guest support (plan)

Goal: orchestrate a Win11 bhyve guest the same way aeo does Linux guests —
boot + contain it (host-side, OS-agnostic), then deploy the Python service into
it.

## CORRECTION (2026-06-25): Aether DOES target Windows — the agent stays Aether

An earlier draft of this doc claimed "no Aether→Windows toolchain" and pivoted to
an ssh-shim. **That was wrong.** Aether has first-class Windows support:
`select(linux:…, windows:…)` compiles to `#ifdef _WIN32` (docs/named-args-and-
select.md lists "Windows, MinGW, MSYS2"; examples use `-lws2_32`, `C:\…` paths),
and aetherc emits C compiled by gcc/clang — so **mingw-w64 produces a native
Windows `.exe`** (docs/bootstrap-from-source.md: "On Windows, build under MSYS2
… mingw-w64-x86_64-gcc"). So the REAL aeo-agent (Aether, sharing protocol /
transport_http / drivers) runs natively in a Win11 guest as a mingw-built .exe —
same agent, same conduit, every platform. No ssh-shim, no Python-as-the-agent.

The two real obstacles are narrower than "Aether can't":
1. **The agent body is Linux-bound, not the language.** bin/aeo-agent.ae
   `import driver_linux` + calls podman. Windows needs a driver_windows (or
   `select()`-based) path that runs the workload natively (install Python via
   winget, launch `python app.py`) instead of podman. A code change.
2. **Need a mingw cross-build** (FreeBSD host → Windows .exe). Extends the
   "build the Linux agent in a container" plan: a toolchain image with
   mingw-w64-gcc cross-compiles the agent's emitted C to a .exe. Known pattern;
   pipeline to be confirmed.

OpenSSH (built into Windows) is still the right ZERO-INSTALL bootstrap to PUSH
the agent .exe in the first time (and as a fallback deploy channel) — but the
agent it pushes is the Aether one, not a shim.

## Containment is already OS-agnostic (no work needed)

The three constraints all act on the HOST against the bhyve process, never
inside the guest, so a Win11 guest is contained identically to Linux:
- Capsicum `grant_fd` — confines the bhyve *process* (disk/tap/console fds).
- pf netpolicy — host firewall on the guest's *tap* (OS-blind). [NOTE: inter-VM
  pf delivery is currently broken on the shared bridge — see
  `pf-enforcement-next-steps.md`; that's host-side and equally affects Windows.]
- rctl caps — host kernel on the bhyve *process* (`process:<pid>`).
Ref: `test/spec_containment_linux_vm.ae` — "the VM BOUNDARY contains it
regardless of guest OS; the contained does not confine itself."

## Capacity (checked 2026-06-25)

Box has room: zroot **267 GB free** (VMs use ~7.5 GB), **31 GB RAM** (1 GB
committed). Allocate ~40 GB disk, 8 GB RAM, 2–4 vCPU for the Win11 VM.

## bhyve specifics for a Windows guest — ALL PREREQS PRESENT (verified 2026-06-25)

The box has everything; nothing to install. Verified on `paul@192.168.0.57`:
- **UEFI bootrom** ✅ `bhyve-firmware` installed, `BHYVE_UEFI.fd` present.
- **VNC framebuffer** (`fbuf`) ✅ + **USB tablet** (`xhci`/`tablet`) ✅ — bhyve
  supports both, so the installer is visible + the mouse works.
- **AHCI disk** (`ahci-hd`) ✅, **NVMe** ✅ — start with AHCI (no virtio-blk in
  Windows OOB).
- **e1000 NIC** ✅ (Windows has the driver built in) — virtio-net is also present
  for later driver-slipstreaming.
- **vm-bhyve 1.7.3** ✅ ships a stock **`windows.conf`** template (the known-good
  config) at `/usr/local/share/examples/vm-bhyve/windows.conf`.
- **ISO datastore** ✅ `/zroot/vm/.iso/` exists (empty, ready for the Win11 ISO).

### ⚠️ Two gotchas in the stock windows.conf
1. **`network0_switch="public"` → change to `aeonat`.** `public` puts the guest
   on the LAN bridge, which the upstream LAN switch's MAC-per-port limit REJECTS
   (the exact reason NAT exists — see bhyve-networking-journey.md). The guest
   must be on the private `aeonat` NAT switch (172.16.0.x) like every other node.
2. The template's `graphics_listen` is commented out — fine, since **Paul is
   physically at the box** (local kbd/mouse/display); no VNC-over-LAN needed.

The stock template otherwise is correct as-is: `loader="uefi"`, `graphics="yes"`,
`xhci_mouse="yes"`, `disk0_type="ahci-hd"`, `network0_type="e1000"`,
`utctime="no"` (Windows expects localtime).

## First-boot runbook (ATTENDED — Paul, physically at the box)

Paul is at the GhostBSD machine with kbd/mouse/display, so drive the installer on
the box's local display — NO VNC-over-LAN needed. `vm console` / the bhyve fbuf
shows on the attached monitor.

1. Copy a Win11 ISO into `/zroot/vm/.iso/` (~6 GB; 267 GB free).
2. Create + install from the stock windows template, on the NAT switch:
   ```
   sudo vm create -t windows -s 40G win11
   sudo vm set win11 network0_switch=aeonat   # ← override 'public' (LAN-switch rejects it)
   sudo vm set win11 memory=8G                 # template default is 2G; bump it
   sudo vm install win11 <iso-name>.iso
   sudo vm console win11                        # opens the display on the local monitor
   ```
3. Install Win11 Home. **Skip the product key** ("I don't have a product key" —
   runs unlicensed/eval, fine for a test VM). MS-account/local-account at OOBE is
   the fiddly 24H2 bit; an `autounattend.xml` is the deterministic fix if the
   in-OOBE skips don't work, but for a first pass just get THROUGH OOBE.
4. **Enable the OpenSSH Server** (built in) — in an admin PowerShell:
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
   then `Start-Service sshd; Set-Service -Name sshd -StartupType Automatic`.
5. **Add Paul's pubkey** to `C:\ProgramData\ssh\administrators_authorized_keys`
   (admin-key path on Windows; perms matter — owner Administrators/SYSTEM only,
   no inherited ACLs).
6. From the host: `ssh paul@<win-guest-ip>` works with key auth (the bootstrap
   channel for pushing the Aether agent .exe later).
7. Give the guest a known static IP on the NAT switch — pick **.60** (aeo-base is
   .50, testpeer .51; avoid the clash the Linux clones hit). Set it inside
   Windows (network adapter → manual IPv4 172.16.0.60/24, gw 172.16.0.1, dns
   172.16.0.1).
8. Tell Claude → snapshot it as the Windows golden (`zfs snapshot
   zroot/vm/win11@golden`, via the granted zfs).

## aeo-side work (AFTER the snapshot exists)

The agent stays Aether; OpenSSH is the bootstrap channel to push it + a fallback.

- [ ] Snapshot the attended Win11 VM as a golden (zfs snapshot, like aeo-base).
- [ ] **driver_windows / `select()` agent path**: give aeo-agent a Windows arm
      that runs the workload natively (winget-install Python, write the app,
      launch `python app.py`) instead of `driver_linux`/podman. This is the agent
      *body* change — the language already targets Windows.
- [ ] **mingw cross-build** of the agent: a toolchain image with mingw-w64-gcc
      compiles the agent's emitted C → `aeo-agent.exe` on the FreeBSD host.
- [ ] **Push over OpenSSH**: the driver scp's `aeo-agent.exe` into the guest and
      starts it (a scheduled task / service for TSR — the Windows analog of the
      systemd/OpenRC init-aware push, see memory aeo-agent-tsr-init-systems).
      OpenSSH also stays as a no-agent fallback deploy channel.
- [ ] Image-recipe / guest_image kind for Windows (the recipe model assumes
      cloud-init/netplan/systemd — Windows uses none; a different realizer).
- [ ] Re-validate containment against the Win11 guest once pf inter-VM delivery
      is fixed (the 2-guest test harness extends to a 3rd, Windows, guest).

## Open

- Licensing: running Win11 unlicensed/eval is your call (MS EULA), not aeo's.
- The OOBE local-account skip on Win11 Home 24H2 is a moving target; have an
  `autounattend.xml` ready as the deterministic fallback.
