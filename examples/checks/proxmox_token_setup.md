# Proxmox VE token for aeo — the CISO-grade setup

`examples/checks/proxmox_token_setup.sh` provisions the API credential aeo uses to
drive a Proxmox VE host. It is built for **high-importance prod in a large org**:
defense-in-depth, least privilege, and a leaked-secret blast radius small enough
that a security team signs off. This note records the model and the **live proof**
that the containment holds.

## The stack (5 independent layers)

| Layer | What | Why it limits harm |
|---|---|---|
| **Dedicated identity** | `aeo@pve` (not `root@pam`) | Own audit trail; disabled/rotated without touching humans. root is used ONCE, to bootstrap. |
| **Least-priv role** | `aeo-deployer` — 16 privileges | Exactly clone→configure→power a VM + read-only guest-agent ping. No `VM.Migrate`, `VM.Snapshot*`, `VM.Backup`, `VM.Console`, `VM.GuestAgent.{Exec,Unrestricted,FileRead,FileWrite}`, `Sys.*`, `Datastore.Allocate`/`AllocateTemplate`, `Pool.Allocate`, `Permissions.Modify`. |
| **Resource pool** | `aeo-prod` — the blast radius | The role is granted on `/pool/aeo-prod` (+ one storage, one SDN zone), **never `/`**. aeo can only see/touch VMs in this pool. |
| **Privilege-separated token** | `aeo@pve!deploy`, `privsep=1` | The token carries its OWN ACL ⊆ the user's. Revoke the token without disabling the user; a token leak ≠ full-user compromise. |
| **Short-lived** | `expire = now + 30d` | A leaked secret self-heals; forces rotation. Tunable via `PVE_TOKEN_TTL_DAYS`. |

The secret is printed **once** (PVE never shows it again) and lives only in your
secrets manager / CI as `PVE_TOKEN` — never in a `.ae` file.

## The 16 privileges, and why each is needed

`VM.Clone` `VM.Allocate` (clone a template into a new VMID) · `VM.Config.{Disk,CPU,Memory,Network,Options,Cloudinit,CDROM}` (shape the guest + seed cloud-init) · `VM.PowerMgmt` (start/stop) · `VM.Audit` (read its status) · `VM.GuestAgent.Audit` (READ-ONLY `/agent/ping` — so aeo's `agent()`-mode probe can confirm the guest OS is alive) · `Datastore.AllocateSpace` `Datastore.Audit` (the disk, on the one granted store) · `SDN.Use` (attach the bridge) · `Pool.Audit` (see its own pool).

`VM.GuestAgent.Audit` is the ONLY guest-agent privilege, and it's read-only ping.
We DELIBERATELY exclude `VM.GuestAgent.Exec` / `.Unrestricted` / `.FileRead` /
`.FileWrite` — **no arbitrary in-guest command execution or file access.** So
agent-based probe works; an exec-in-as-ignition path (if ever built) would need a
further, separate grant a CISO reviews on its own merits. Nothing here can migrate,
snapshot, back up, open a console, reconfigure the node/cluster, allocate new
storage/templates, or modify permissions.

Adding `VM.GuestAgent.Audit` did NOT weaken any dangerous-mutation denial — the
create-user / self-ACL-escalate / node-reboot 403s below are unchanged (verified by
`test/spec_pve_host_live.ae`, which stays green with the widened role).

## Post-provision: the operator also places the cloud-init snippet

A `proxmox_vm` completes its node IN-GUEST via cloud-init (generic template, not a
baked workload). Like the template, the operator places the snippet ONCE; the
least-priv token then REFERENCES it (proven: setting `cicustom` needs only VM-write,
not storage-write):
```sh
scp examples/checks/proxmox_cloudinit.yaml root@<pve>:/var/lib/vz/snippets/aeo-agent-init.yaml
ssh root@<pve> "pvesm set local --content iso,vztmpl,backup,snippets"   # enable snippets
```
Then the composition uses `cloud_init("local:snippets/aeo-agent-init.yaml")` +
`agent(1)`. The snippet installs qemu-guest-agent (makes `/agent/*` live) and
writes an `AEO_PROVISIONED` marker; aeo's `agent()`-probe waits for the guest-agent
to respond before promoting the node to UP.

## Live proof (against 192.168.0.204, 2026-07-11)

Verified with the issued token itself. PVE's REST model is: **list endpoints
privilege-FILTER** (return only what you're entitled to), **mutating endpoints
outside scope hard-403**. Both behaviours were confirmed.

**Allowed — exactly aeo's job:**
```
read own pool /pools/aeo-prod          -> 200
audit VMs     /nodes/pve/qemu          -> 200
/pool/aeo-prod effective privs         -> the 16 above, and only those
```

**Scoped visibility — the token sees ONLY its slice (200, but filtered):**
```
/access/users        -> 0 rows      (cannot enumerate users)
/access/acl          -> []          (cannot read cluster ACLs)
/cluster/resources   -> 3 rows      (its pool, its node, its storage — nothing else)
/nodes/pve/hardware  -> {pci,usb} category labels only (no device detail)
```

**Denied — every dangerous mutation hard-403s:**
```
POST /access/users                      -> 403   (can't create identities)
PUT  /access/acl  path=/  Administrator -> 403   (can't self-escalate — the token-escape)
PUT  /nodes/pve/network                 -> 403   (can't touch node networking)
POST /nodes/pve/status  command=reboot  -> 403   (can't reboot the node)
POST /nodes/pve/storage/local/upload    -> 403   (can't write un-granted storage)
GET  /nodes/pve/syslog                  -> 403   (can't read host logs)
```

A stolen `aeo@pve!deploy` token can create/start VMs **in `aeo-prod` only**, and
can do nothing to the node, the cluster, other tenants, or its own privileges. It
expires in 30 days regardless.

## Usage

```sh
# provision (bootstraps as root@pam once, then never uses it again)
PVE_HOST=192.168.0.204:8006 PVE_ADMIN_PASS='…' sh examples/checks/proxmox_token_setup.sh

export PVE_TOKEN="aeo@pve!deploy=<secret-shown-once>"   # → secrets manager / CI

# rotate or fully tear down (token → ACL → pool → user → role)
PVE_HOST=192.168.0.204:8006 PVE_ADMIN_PASS='…' sh examples/checks/proxmox_token_setup.sh --revoke
```

Tunables: `PVE_REALM` (pve), `PVE_POOL` (aeo-prod), `PVE_STORAGE` (local-lvm),
`PVE_TOKEN_TTL_DAYS` (30). The script is idempotent — re-running rotates the token
and reconciles the role/pool/ACL in place.

The composition (`examples/silly_addition_proxmox.ae`) reads the token via
`auth_token(getenv("PVE_TOKEN"))`; the secret never touches the model.
