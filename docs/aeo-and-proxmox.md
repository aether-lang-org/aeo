# aeo and Proxmox VE — BUILT + live-proven

**STATUS: BUILT + LIVE-PROVEN, end-to-end, on a fresh Proxmox host.** `aeo up
examples/silly_addition_proxmox.ae` clones a template, configures cloud-init, and
boots VMs on a remote Proxmox VE host over its HTTPS API (:8006); `aeo down` destroys
them. Every 8006 call is verified against PVE's own CA (couriered over ssh — no blind
trust). The full flow was re-run from bare on a just-reformatted box: three one-time
setup scripts, then `check`/`up`/`down` with zero hand-tweaks.

Proxmox is aeo's **first REMOTE substrate**. Every other cell (containers, jails,
bhyve, kvm, lxc) runs aeo *on* the box the workload lands on and shells out locally.
Here aeo runs *anywhere* (a Chromebook) and addresses a Proxmox host **over an API** —
the "remote host" the composition names by endpoint + token. The workload VMs live on
PVE; aeo is a client.

---

## The model: provision once, orchestrate many

The single most important idea. There are two cadences, and they map to two different
tools on purpose:

| | Cadence | Tool | Channel | Privilege |
|---|---|---|---|---|
| **Provision** | once per **host** (+ credential rotation) | shell scripts | ssh (root) | root on the hypervisor |
| **Orchestrate** | thousands of times per host | `aeo` commands | 8006 API | pool-scoped least-priv token |

**Why shell for provisioning:** building a cloud-init template, placing a snippet, and
creating a pool are *imperative host administration* (`qm`, `pvesh`, `scp`,
`systemctl`) — work the 8006 API cannot do (it has no host-shell endpoint) and that
aeo's declarative model is not for. This is the substrate prep *underneath* aeo, the
exact analog of `apt install podman` or standing up a jail host once. Shell is the
honest home; these scripts are not a shortcut.

**Why aeo for the hot path:** `check`/`up`/`down` are pure 8006 API, declarative (the
composition IS the spec), and run per-deploy. This is what aeo is for.

**A strong property of the split:** `check`/`up`/`down` NEVER shell to the host — they
touch only 8006 with the token + pinned CA. SSH exists *only* for the setup scripts
(and the optional host-agent). So a hardened deploy can **revoke the orchestrator's SSH
access after provisioning** and still run `aeo up`/`down` forever on just the token and
cert. The hot path needs no root, no ssh, no host access.

---

## Runbook: a fresh orchestrator → a running deploy

Prerequisites: a reachable Proxmox host, root ssh to it (once), and the `aeo` binary
plus a checkout of this repo on the orchestrator.

### One-time host setup (ssh root@\<pve\>, per new host)

```sh
# 1. build the template + pool + doer snippet (idempotent; --uninstall to reverse)
PVE_SSH=root@<pve> sh examples/checks/proxmox_bootstrap.sh

# 2. mint the least-privilege API token (CISO-grade; see the security section)
PVE_HOST=<pve>:8006 PVE_ADMIN_PASS=... sh examples/checks/proxmox_token_setup.sh
#    -> prints:  export PVE_TOKEN="aeo@pve!deploy=<secret>"

# 3. courier PVE's own CA back to the orchestrator (for TLS pinning)
PVE_SSH=root@<pve> sh examples/checks/proxmox_pin_ca.sh
#    -> writes ./pve-root-ca.pem, prints:  export AEO_PVE_CACERT=".../pve-root-ca.pem"
```

**Order matters.** `bootstrap` creates the pool; `token_setup` grants the token's ACL
*on* that pool. If the pool is (re)created after the token is set, the token's ACL is
orphaned and it sees no template ("template not visible"). `token_setup` is idempotent —
re-run it after any `bootstrap` (it re-grants and rotates the token).

### Deploy (pure 8006 API, verified TLS, least-priv token — repeat forever)

```sh
export PVE_TOKEN="aeo@pve!deploy=<secret>"          # from step 2
export AEO_PVE_CACERT="$(pwd)/pve-root-ca.pem"      # from step 3

aeo check examples/silly_addition_proxmox.ae        # model + remote-host preflight
aeo up    examples/silly_addition_proxmox.ae        # clone → cloud-init → start
aeo down  examples/silly_addition_proxmox.ae        # stop → destroy
```

`token_setup` mints a token that **expires in 30 days** by design — so the honest
cadence is "provision once, rotate the token occasionally, orchestrate constantly."

---

## The grammar

A `proxmox_vm` is a flat leaf VM (like `kvm_vm`) that names WHERE + HOW to reach the
remote host and WHAT to clone:

```javascript
proxmox_vm("db_vm") {
    host("192.168.0.204:8006")        // PVE API endpoint
    node("pve")                        // the cluster node to place it on
    auth_token(getenv("PVE_TOKEN"))    // least-priv token — never in the file
    storage("local-lvm")               // where the VM disk lands
    bridge("vmbr0")                     // the guest NIC's bridge
    template("debian-12-cloudinit")    // clone source (bootstrap builds it)

    // OPTIONAL post-provision (in-guest completion via aeo-agent):
    cloud_init("local:snippets/aeo-agent-init.yaml")  // the doer snippet
    agent(1)                            // probe waits for the guest-agent (guest OS alive)

    cpus(2); memory("2G")
}
```

`aeo check` runs a model gate (host/node/auth_token/template required — a missing/empty
token, usually an unset `PVE_TOKEN`, fails LOUD) AND a live **remote-host preflight**:
it reaches the box with the token and verifies deploy-readiness (template is a pool
member, storage + bridge exist). A reachable-but-misconfigured host fails; an
unreachable one (checking offline) warns and still validates the model.

### LXC containers — `proxmox_ct`

The sibling kind for native Proxmox **LXC containers**. A CT is fundamentally
different from a VM: it is **created from an OS template TARBALL** (`ostemplate`, a
`vztmpl` volid) via the `/lxc` API, NOT cloned from a VM template. Lighter (shared
kernel, boots in seconds), no cloud-init/guest-agent.

```javascript
proxmox_ct("db_ct") {
    host("192.168.0.204:8006"); node("pve"); auth_token(getenv("PVE_TOKEN"))
    storage("local-lvm"); bridge("vmbr0")
    ostemplate("local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst")  // the tarball
    rootfs("local-lvm:2")                                                // <storage>:<GiB>
    cpus(1); memory("512")
}
```

Demo: [`silly_addition_proxmox_ct.ae`](../examples/silly_addition_proxmox_ct.ae)
(two CTs, `db_ct` ← `app_ct`; `up`/`down` live-proven). Two operator prereqs beyond
the VM path: **download the OS tarball** once (`pveam download local
debian-12-standard...tar.zst`), and the token needs **Datastore read on the vztmpl
storage** (`proxmox_token_setup.sh` grants `TEMPLATE_STORE`, default `local`) — a CT
create without it 403s. One driver serves both kinds (`_ep()` routes `/lxc` vs
`/qemu`); `check`/`up`/`down` and the CA-pin are identical.

Note on privsep tokens: a token's effective perms are the **intersection** of the
user's and the token's ACLs, so a grant must go to BOTH (the setup script does this).

---

## Security model

The credential is the part a CISO signs off on for prod. Full detail + the live
allowed-vs-denied evidence is in
[`examples/checks/proxmox_token_setup.md`](../examples/checks/proxmox_token_setup.md);
the shape:

- **Dedicated service user** `aeo@pve` (not root) — own audit trail, revocable.
- **Custom least-priv role** `aeo-deployer` — exactly the ~16 privileges to
  clone/configure/power a VM + read-only guest-agent ping. NO Migrate, Snapshot,
  Backup, Console, Sys.\*, GuestAgent.Exec/Unrestricted/File\*, or Permissions.Modify.
- **Resource-pool blast radius** `aeo-prod` — the role is granted only on
  `/pool/aeo-prod` (+ the one storage, one SDN zone), never on `/`. A stolen token can
  create/start VMs in that pool and do nothing else (proven: create-user,
  self-ACL-escalate, node-reboot all hard-403).
- **Privilege-separated, expiring token** — the token carries its own ACL ⊆ the user's,
  and expires (30 days default).

**TLS pinning ("the 1970s inter-bank courier").** PVE ships a private CA — no public
chain. `proxmox_pin_ca.sh` couriers `/etc/pve/pve-root-ca.pem` back over the initial
ssh; the driver then **verifies every 8006 call against exactly that cert**
(`set_cafile` + `set_insecure(0)`), rejecting any other cert fail-closed. This is
strictly stronger than the accept-any fallback (used only when `AEO_PVE_CACERT` is
unset). It relies on aether's `std.http.client.set_cafile` (custom-CA pin).

---

## Post-provision: the in-guest doer (optional)

The design decision (debated and spiked live): the template stays a **generic** cloud
image; the node completes its identity **in-guest** via `aeo-agent`, NOT by baking a
workload into the template. This is aeo's native "act inside, report outward" recursion
— a PVE VM is just another boundary; the agent one level down completes it.

The chain (all live-proven): `aeo up` → driver sets `cicustom` → cloud-init installs
`qemu-guest-agent` + **fetches `aeo-agent` from GitHub Releases and SHA-verifies it**
(fail-closed) + starts it → the agent runs the workload **container** (podman) and
reports outward. `agent(1)` makes `probe()` wait for the guest-agent to respond (guest
OS alive) before promoting the node to UP.

- **Delivery:** `aeo-agent` is fetched from an immutable, versioned GitHub Release
  (`aeo-agent-v*`, asset `aeo-agent-linux-x86_64-glibc`), built by
  `.github/workflows/release-aeo-agent.yml`. A PVE cicustom snippet is text-only and
  PVE has no snippet-write API, so the guest *fetches* — Releases is the durable,
  checksummed host. The snippet is [`proxmox_cloudinit.yaml`](../examples/checks/proxmox_cloudinit.yaml).
- **Host-side agent (optional):**
  [`proxmox_host_agent_install.sh`](../examples/checks/proxmox_host_agent_install.sh)
  installs `aeo-agent` ON the PVE host as a loopback systemd listener (fetched from
  GH-releases, SSH-gated). Binds 127.0.0.1 only — reachable via ssh tunnel + token.

---

## Honest frontier

What's built is real; these are the documented follow-ups (see `TODO.md`):

- **Per-node identity + token seeding.** A generic cloud image boots hostname
  `localhost`, so the in-guest `AEO_NODE` is `localhost` rather than the node name.
  Both clean fixes are blocked for the least-priv token (SMBIOS needs
  `VM.Config.HWType`; PVE NoCloud meta-data carries no hostname and cicustom overrides
  the default). The path is: driver generates a per-node cicustom (hostname + AEO_NODE +
  a `lib/secrets`-sealed token) placed via ssh. Doer *mechanics* are proven; this is
  the identity/secret polish.
- **Host-agent health multiplexer.** The host listener is installed and reachable, but
  doesn't yet DO the sub-runner job (reach the guests over the bridge, aggregate their
  health, report one signal outward). Reconcile with the aeo-supervisor design.
- **Guest reachability is box-specific.** On a LAN-bridged box, guests get LAN IPs and
  are directly reachable from the orchestrator; on a hardened prod PVE (isolated/NAT'd
  guest bridge, hypervisor firewalled to 8006) the reachability story is tighter.

---

## Files

| Path | What |
|---|---|
| `lib/driver_proxmox/module.ae` | the API client (clone/config/start/stop/destroy/probe/preflight), CA-pinned |
| `lib/compose/module.ae` | the `proxmox_vm` grammar + model gate |
| `examples/silly_addition_proxmox.ae` | the VM demo composition + runbook comments |
| `examples/silly_addition_proxmox_ct.ae` | the LXC-CT demo composition |
| `examples/checks/proxmox_bootstrap.sh` | **(1)** one-time host setup: template + pool + snippet |
| `examples/checks/proxmox_token_setup.sh` / `.md` | **(2)** least-priv token + the security proof |
| `examples/checks/proxmox_pin_ca.sh` | **(3)** courier PVE's CA for TLS pinning |
| `examples/checks/proxmox_cloudinit.yaml` | the in-guest doer snippet (fetches aeo-agent) |
| `examples/checks/proxmox_host_agent_install.sh` | optional host-resident agent (systemd) |
| `examples/checks/proxmox_model.spec.ae` / `proxmox_suite.spec.ae` | model + suite specs |
| `.github/workflows/release-aeo-agent.yml` | versioned GitHub Release of aeo-agent |
