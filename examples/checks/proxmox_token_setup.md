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
| **Least-priv role** | `aeo-deployer` — 15 privileges | Exactly clone→configure→power a VM. No `VM.Migrate`, `VM.Snapshot*`, `VM.Backup`, `VM.Console`, `VM.GuestAgent.*`, `Sys.*`, `Datastore.Allocate`/`AllocateTemplate`, `Pool.Allocate`, `Permissions.Modify`. |
| **Resource pool** | `aeo-prod` — the blast radius | The role is granted on `/pool/aeo-prod` (+ one storage, one SDN zone), **never `/`**. aeo can only see/touch VMs in this pool. |
| **Privilege-separated token** | `aeo@pve!deploy`, `privsep=1` | The token carries its OWN ACL ⊆ the user's. Revoke the token without disabling the user; a token leak ≠ full-user compromise. |
| **Short-lived** | `expire = now + 30d` | A leaked secret self-heals; forces rotation. Tunable via `PVE_TOKEN_TTL_DAYS`. |

The secret is printed **once** (PVE never shows it again) and lives only in your
secrets manager / CI as `PVE_TOKEN` — never in a `.ae` file.

## The 15 privileges, and why each is needed

`VM.Clone` `VM.Allocate` (clone a template into a new VMID) · `VM.Config.{Disk,CPU,Memory,Network,Options,Cloudinit,CDROM}` (shape the guest + seed cloud-init) · `VM.PowerMgmt` (start/stop) · `VM.Audit` (read its status) · `Datastore.AllocateSpace` `Datastore.Audit` (the disk, on the one granted store) · `SDN.Use` (attach the bridge) · `Pool.Audit` (see its own pool).

Nothing here can migrate, snapshot, back up, open a console, run guest-agent
commands, reconfigure the node/cluster, allocate new storage/templates, or modify
permissions.

## Live proof (against 192.168.0.204, 2026-07-11)

Verified with the issued token itself. PVE's REST model is: **list endpoints
privilege-FILTER** (return only what you're entitled to), **mutating endpoints
outside scope hard-403**. Both behaviours were confirmed.

**Allowed — exactly aeo's job:**
```
read own pool /pools/aeo-prod          -> 200
audit VMs     /nodes/pve/qemu          -> 200
/pool/aeo-prod effective privs         -> the 15 above, and only those
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
