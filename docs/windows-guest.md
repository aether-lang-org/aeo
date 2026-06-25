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
