# Windows 11 guest support (plan)

Goal: orchestrate a Win11 bhyve guest the same way aeo does Linux guests —
boot + contain it (host-side, OS-agnostic), then deploy the Python service into
it. Chosen approach: **drive Windows over SSH** (the OpenSSH Server that ships
*with* Windows), so the deploy path mirrors the Linux ssh path; no Aether agent
inside Windows (there's no Aether→Windows toolchain).

## Why SSH, not an in-guest aeo-agent

The Aether `aeo-agent` can't be compiled for Windows (Aether emits C; no Windows
target). And an agent can't install its own runtime — something must already be
in the snapshot. OpenSSH Server is BUILT IN to Windows, so enabling it is the
minimal bootstrap: aeo then ssh's in and runs commands (install Python, run the
service) per-deploy — the "agent installs Python" idea, realized as aeo's own
ssh-driven commands rather than a resident binary. Same seam as Linux
(`driver_vm.guest_container_up` ssh's in), different in-guest commands.

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

## bhyve specifics for a Windows guest (likely gotchas, UNVERIFIED)

Windows needs different device models than our Linux template:
- **UEFI bootrom** (have it — bhyve-firmware) + likely a **GOP/framebuffer +
  VNC** so you can SEE the installer (Linux guests run headless; Windows OOBE
  needs a display). vm-bhyve: a `graphics="yes"` + `vnc` template.
- **Disk:** AHCI (`ahci-hd`) or NVMe — Windows has no virtio-blk driver out of
  the box (would need virtio drivers slipstreamed). Start with AHCI.
- **NIC:** `e1000` (Windows has a built-in driver); virtio-net needs the
  Fedora virtio-win drivers injected. Start with e1000.
- A `windows` guest template for vm-bhyve (vs the `linux-nat` one) — TBD.

## First-boot runbook (ATTENDED — Paul)

1. Get a Win11 ISO onto the box (~6 GB; space is fine).
2. Create the VM with a Windows-shaped template (UEFI + VNC + AHCI + e1000),
   ~40 GB disk, boot the ISO, connect via VNC.
3. Install Win11 Home. **Skip the product key** ("I don't have a product key" —
   runs unlicensed/eval, fine for a test VM). MS-account/local-account at OOBE is
   the fiddly 24H2 bit; an `autounattend.xml` is the deterministic fix if the
   in-OOBE skips don't work, but for a first pass just get THROUGH OOBE.
4. **Enable the OpenSSH Server** (built in):
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
   then `Start-Service sshd; Set-Service -Name sshd -StartupType Automatic`.
5. **Add Paul's pubkey** to `C:\ProgramData\ssh\administrators_authorized_keys`
   (admin-key path on Windows; perms matter — owner Administrators/SYSTEM only).
6. Confirm `ssh paul@<win-guest-ip>` works from the host with key auth.
7. Give the guest a known static IP on the NAT switch (avoid the .50 clash the
   Linux clones hit — pick e.g. .60).
8. Tell Claude → snapshot it as the Windows golden.

## aeo-side work (AFTER the snapshot exists)

- [ ] Snapshot the attended Win11 VM as a golden (zfs snapshot, like aeo-base).
- [ ] A Windows deploy path in the driver: detect a Windows guest, ssh in, and
      run Windows commands — install Python (winget/python.org silent), write
      the app, launch it — instead of the Linux podman path. Parallels
      `guest_container_up`; a `guest_winsvc_up` sibling.
- [ ] Image-recipe / guest_image kind for Windows (the recipe model assumes
      cloud-init/netplan/systemd — Windows uses none; a different realizer).
- [ ] Re-validate containment against the Win11 guest once pf inter-VM delivery
      is fixed (the 2-guest test harness extends to a 3rd, Windows, guest).

## Open

- Licensing: running Win11 unlicensed/eval is your call (MS EULA), not aeo's.
- The OOBE local-account skip on Win11 Home 24H2 is a moving target; have an
  `autounattend.xml` ready as the deterministic fallback.
