# Linux host setup for aeo (rootless podman substrate)

What a Linux box needs to run aeo's container tiers. Most of aeo is **rootless** —
`container()`/`lxc()` bring-up, confinement (cgroups/seccomp/netpolicy), gpu(), and
the blue-green cutover all run as your user with no root. A few **host-mutating**
operations need `sudo`, and aeo runs them **non-interactively** (`sudo -n`, never
prompt) — so those specific commands must be granted **NOPASSWD** in sudoers. This is
the same contract the pf / nspawn / lxc paths use (cf. `docs/bsd-host-setup.md`).

Reference box: `paul@192.168.0.160` — CachyOS (Arch), **podman 6.0.0**, cgroups v2,
`pasta 2026_06_11`, Intel N100 iGPU.

---

## 1. Rootless podman (no root)

```sh
# Arch/CachyOS
sudo pacman -S podman passt   # passt provides pasta (podman 6's rootless net stack)
```
Rootless containers, published ports, shared networks, cgroup-v2 confinement, and
`--device` GPU mapping all work with no further privilege. Nothing here needs sudo.

## 2. NOPASSWD sudo grants (only for host-mutating ops)

aeo runs these as `sudo -n <full-path> …`. Grant exactly the binaries it invokes —
full paths, so a path-specific rule matches and nothing broader is opened up.

### pasta port-forwarder (`aeo pasta … on|off`)

`aeo pasta … on` writes a `containers.conf.d` drop-in switching the rootless port
forwarder to **pasta** (preserve the client source IP — see §3). It needs:

```sh
sudo tee /etc/sudoers.d/aeo-pasta >/dev/null <<'SUDO'
%wheel ALL=(root) NOPASSWD: /usr/bin/mkdir -p /etc/containers/containers.conf.d, \
                            /usr/bin/tee /etc/containers/containers.conf.d/aeo-pasta.conf, \
                            /usr/bin/rm -f /etc/containers/containers.conf.d/aeo-pasta.conf
SUDO
sudo chmod 440 /etc/sudoers.d/aeo-pasta
```

Without this, `aeo pasta … on` fails loud with a pointer here (it never hangs on a
password prompt — `sudo -n` fails fast). `status` and `off` of an absent drop-in need
no grant.

### Other tiers (as you use them)

- **lxc** (`lxc()` nodes) — the `lxc-*` binaries + the snapshot grant. See the
  sudoers note in `lib/driver_lxc/module.ae`.
- **nspawn** (`nspawn()` nodes) — `systemd-run`, `systemctl`, `machinectl`. See
  `lib/driver_nspawn/module.ae`.
- **image recipes** (`systemd_unit()` in a `realize_as` build) — `tee` +
  `systemctl` for the in-guest unit writes.

`container()` / `bwrap()` need **none** of these — they are fully rootless.

---

## 3. Source-IP fidelity: the pasta forwarder

A rootless published port (`-p`) defaults to **`rootlessport`**, a userspace proxy
that rewrites the client source to its own gateway — a LAN client `192.168.0.x`
arrives at your app as `169.254.x.x` (verified live on podman 6.0.0). That breaks any
IP-based defence (brute-force lockout, ban lists) and pollutes the audit trail.

`aeo pasta <compose.ae> on` writes:

```ini
# /etc/containers/containers.conf.d/aeo-pasta.conf
[network]
rootless_port_forwarder = "pasta"
```

which switches the forwarder to **pasta** (kernel-level forwarding via *pesto*).

**Status — root-caused live 2026-07-05 (podman 6.0.0 + pasta/pesto 2026_06_11):**
the drop-in switches the forwarder to pasta, and on a **bridge** network (which is
exactly what aeo's `up` path uses — `aeo-<system>`) the **pesto** source-preserving
path fully engages. Verified: podman starts a shared `pasta … -c …/pasta.sock`
instance and the `pasta.sock` control socket is present — the
[podman #28478](https://github.com/podman-container-tools/podman/pull/28478)
mechanism. This is **shipped in podman 6.0.0, not upstream-pending** (an earlier note
here was wrong).

The one thing **not** provable on the reference box: whether a genuine **external
LAN client's** source IP survives. pasta starts with `--map-guest-addr 169.254.1.2`,
so **host-originated** traffic to a published port (the host curling its own `-p`)
is mapped to that guest-addr by pasta's loopback/splice path *by design* — you will
see `169.254.x` from a host-local client even when pesto is active. Only a **real
remote host** arriving over the LAN interface takes the TAP path where the true
source is preserved, and we had no third LAN host to exercise it. So: the mechanism
aeo writes is correct and fully wired; external-client source preservation is pasta's
documented behavior on this path but is **unverified here** (a test-harness limit —
not an aeo gap, not an upstream wait). `aeo pasta … status` reports what is actually
in effect; aeo never claims a preservation it observed.

> **Testing tip:** don't test source-IP fidelity by curling the host's own published
> port — that's the loopback path and always shows the guest-addr. Use a separate
> physical host on the LAN.

```sh
aeo pasta compose.ae status   # OFF (rootlessport) | ACTIVE (pasta)
aeo pasta compose.ae on       # write the drop-in (needs the NOPASSWD grant, §2)
aeo pasta compose.ae off      # revert to rootlessport
```

> **Restart guard (podman #29032):** stale pasta forward rules can conflict on a
> container restart. aeo's teardown verifies disappearance; if a node fails to come
> back up on a pasta host, `aeo pasta … off` then `on` clears the drop-in state.
