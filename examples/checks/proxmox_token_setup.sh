#!/bin/sh
# proxmox_token_setup.sh — provision a LEAST-PRIVILEGE Proxmox VE API token for aeo.
#
# This is the token setup a CISO signs off on for high-importance prod in a large
# org. It does NOT hand aeo root; it builds a defense-in-depth stack:
#
#   1. A DEDICATED SERVICE USER  (aeo@pve)         — not root@pam. Own identity,
#                                                    own audit trail, disable-able.
#   2. A CUSTOM LEAST-PRIVILEGE ROLE (aeo-deployer) — exactly the ~14 privileges
#                                                    needed to clone+configure+
#                                                    power a VM. No Migrate, no
#                                                    Snapshot, no Backup, no
#                                                    GuestAgent, no Sys.*, no
#                                                    Permissions.Modify.
#   3. A RESOURCE POOL (aeo-prod)                  — the blast radius. The role is
#                                                    granted ONLY on /pool/aeo-prod
#                                                    (+ the one storage + SDN zone),
#                                                    never on '/'. aeo can touch
#                                                    ONLY VMs in this pool.
#   4. A PRIVILEGE-SEPARATED, EXPIRING TOKEN (aeo@pve!deploy)
#                                                    — privsep=1: the token carries
#                                                    its OWN ACL, so it can be scoped
#                                                    tighter than the user and
#                                                    revoked without touching the
#                                                    user. expire= a Unix ts so a
#                                                    leaked secret self-heals.
#
# The secret is printed ONCE (PVE never shows it again). Put it in your secrets
# manager and export PVE_TOKEN before `aeo up` — it never lives in a .ae file.
#
# WHY a CISO is pleased (defense-in-depth, each layer independently limits harm):
#   - Least privilege        : role has no privilege aeo doesn't use.
#   - Blast-radius scoping   : pool ACL — a stolen token can't touch prod VMs
#                              outside aeo-prod, can't read other tenants, can't
#                              reconfigure the node or the cluster.
#   - Separate identity      : aeo@pve is audited/revoked independently of humans.
#   - Privilege separation   : the TOKEN's ACL ⊆ the user's; revoke token, keep user.
#   - Short-lived credential : expire= bounds the window a leak is useful.
#   - No standing root       : root@pam is used ONCE here to bootstrap, then not by aeo.
#   - Auditable & reversible : every grant is explicit; --revoke tears it all down.
#
# Usage:
#   PVE_HOST=192.168.0.204:8006 PVE_ADMIN_PASS='...' sh proxmox_token_setup.sh
#   PVE_HOST=192.168.0.204:8006 PVE_ADMIN_PASS='...' sh proxmox_token_setup.sh --revoke
#
# Requires: curl, python3. Idempotent: re-running updates role/pool/ACL in place.
set -eu

PVE_HOST="${PVE_HOST:-192.168.0.204:8006}"
PVE_ADMIN_USER="${PVE_ADMIN_USER:-root@pam}"          # bootstrap identity (used once)
PVE_REALM="${PVE_REALM:-pve}"                          # service user's realm
SVC_USER="aeo@${PVE_REALM}"
ROLE="aeo-deployer"
POOL="${PVE_POOL:-aeo-prod}"
TOKEN_NAME="deploy"
TOKENID="${SVC_USER}!${TOKEN_NAME}"
STORAGE="${PVE_STORAGE:-local-lvm}"                    # the ONE datastore aeo may use
TTL_DAYS="${PVE_TOKEN_TTL_DAYS:-30}"                   # short-lived by default
API="https://${PVE_HOST}/api2/json"

# The MINIMAL privilege set: clone a template, give it disk/cpu/mem/net/cloud-init,
# power it on/off, read its status — and NOTHING else. Trimmed from PVEVMAdmin.
PRIVS="VM.Clone,VM.Allocate,VM.Config.Disk,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.Cloudinit,VM.Config.CDROM,VM.PowerMgmt,VM.Audit,Datastore.AllocateSpace,Datastore.Audit,SDN.Use,Pool.Audit"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need curl; need python3

if [ -z "${PVE_ADMIN_PASS:-}" ]; then
    printf 'admin (%s) password: ' "$PVE_ADMIN_USER" >&2
    stty -echo 2>/dev/null || true; read -r PVE_ADMIN_PASS; stty echo 2>/dev/null || true; echo >&2
fi

# --- bootstrap: get a ticket as the admin (root@pam), used ONLY for this setup ---
echo "[*] authenticating $PVE_ADMIN_USER to $PVE_HOST (bootstrap only)…" >&2
TICKET_JSON=$(curl -sk --data-urlencode "username=$PVE_ADMIN_USER" \
                       --data-urlencode "password=$PVE_ADMIN_PASS" \
                       "$API/access/ticket")
TICKET=$(printf '%s' "$TICKET_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["ticket"])' 2>/dev/null || true)
CSRF=$(printf '%s'  "$TICKET_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["CSRFPreventionToken"])' 2>/dev/null || true)
[ -n "$TICKET" ] || { echo "auth failed (check PVE_ADMIN_PASS)"; exit 1; }

# thin wrappers — every privileged call carries the cookie + CSRF header.
api() {  # api METHOD PATH [--data-urlencode k=v ...]
    _m="$1"; _p="$2"; shift 2
    curl -sk -X "$_m" -b "PVEAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF" "$@" "$API$_p"
}
code() {  # like api() but print only the HTTP status
    _m="$1"; _p="$2"; shift 2
    curl -sk -o /dev/null -w '%{http_code}' -X "$_m" -b "PVEAuthCookie=$TICKET" \
        -H "CSRFPreventionToken: $CSRF" "$@" "$API$_p"
}

if [ "${1:-}" = "--revoke" ]; then
    echo "[*] tearing down (token → ACL → pool → user → role)…" >&2
    api DELETE "/access/users/${SVC_USER}/token/${TOKEN_NAME}" >/dev/null 2>&1 || true
    api PUT  "/access/acl" --data-urlencode "path=/pool/${POOL}" \
        --data-urlencode "roles=${ROLE}" --data-urlencode "users=${SVC_USER}" \
        --data-urlencode "delete=1" >/dev/null 2>&1 || true
    api DELETE "/pools/${POOL}" >/dev/null 2>&1 || true
    api DELETE "/access/users/${SVC_USER}" >/dev/null 2>&1 || true
    api DELETE "/access/roles/${ROLE}" >/dev/null 2>&1 || true
    echo "[✓] revoked." >&2
    exit 0
fi

# --- 1. custom least-privilege role (create or update-in-place) -----------------
echo "[*] role  $ROLE  ← ${PRIVS}" >&2
if [ "$(code GET "/access/roles/${ROLE}")" = "200" ]; then
    api PUT "/access/roles/${ROLE}" --data-urlencode "privs=${PRIVS}" >/dev/null
else
    api POST "/access/roles" --data-urlencode "roleid=${ROLE}" --data-urlencode "privs=${PRIVS}" >/dev/null
fi

# --- 2. dedicated service user (not root) ---------------------------------------
echo "[*] user  $SVC_USER  (dedicated service identity)" >&2
api POST "/access/users" --data-urlencode "userid=${SVC_USER}" \
    --data-urlencode "comment=aeo orchestrator service account" \
    --data-urlencode "enable=1" >/dev/null 2>&1 || true   # already-exists is fine

# --- 3. resource pool = the blast radius ----------------------------------------
echo "[*] pool  $POOL  (aeo may touch ONLY VMs in this pool)" >&2
api POST "/pools" --data-urlencode "poolid=${POOL}" \
    --data-urlencode "comment=aeo-managed prod VMs" >/dev/null 2>&1 || true

# --- 4. ACLs — grant the role ONLY on narrow paths, never on '/' -----------------
# The pool (the VMs), the one datastore (disks), the SDN zone (bridge). No node,
# no cluster, no other storage. propagate=1 so pool members inherit.
echo "[*] acl   ${ROLE} @ /pool/${POOL}, /storage/${STORAGE}, /sdn/zones (scoped)" >&2
api PUT "/access/acl" --data-urlencode "path=/pool/${POOL}" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "users=${SVC_USER}" \
    --data-urlencode "propagate=1" >/dev/null
api PUT "/access/acl" --data-urlencode "path=/storage/${STORAGE}" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "users=${SVC_USER}" \
    --data-urlencode "propagate=1" >/dev/null
# SDN zone grant (bridge attach). Best-effort: on a box with no SDN zones the
# path may not resolve; the vmbr bridge attach still works via the storage/pool
# grant on many setups. Left explicit so the intent is auditable.
api PUT "/access/acl" --data-urlencode "path=/sdn/zones" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "users=${SVC_USER}" \
    --data-urlencode "propagate=1" >/dev/null 2>&1 || \
    echo "    (note: /sdn/zones grant skipped — no SDN zone on this box; not fatal)" >&2

# --- 5. privilege-separated, EXPIRING token -------------------------------------
# expire = now + TTL_DAYS, computed here (the .ae model can't call Date.now()).
EXPIRE=$(TTL="$TTL_DAYS" python3 -c "import time,os;print(int(time.time())+int(os.environ['TTL'])*86400)")
echo "[*] token ${TOKENID}  privsep=1  expire=+${TTL_DAYS}d" >&2
api DELETE "/access/users/${SVC_USER}/token/${TOKEN_NAME}" >/dev/null 2>&1 || true  # rotate
TOK_JSON=$(api POST "/access/users/${SVC_USER}/token/${TOKEN_NAME}" \
    --data-urlencode "privsep=1" \
    --data-urlencode "expire=${EXPIRE}" \
    --data-urlencode "comment=aeo deploy token (least-priv, expiring)")
SECRET=$(printf '%s' "$TOK_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["value"])' 2>/dev/null || true)
[ -n "$SECRET" ] || { echo "token create failed:"; printf '%s\n' "$TOK_JSON"; exit 1; }

# A privsep token starts with ZERO privileges until its OWN ACL is set. Grant the
# same scoped role to the tokenid so the token — not just the user — is authorized.
api PUT "/access/acl" --data-urlencode "path=/pool/${POOL}" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "tokens=${TOKENID}" \
    --data-urlencode "propagate=1" >/dev/null
api PUT "/access/acl" --data-urlencode "path=/storage/${STORAGE}" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "tokens=${TOKENID}" \
    --data-urlencode "propagate=1" >/dev/null
api PUT "/access/acl" --data-urlencode "path=/sdn/zones" \
    --data-urlencode "roles=${ROLE}" --data-urlencode "tokens=${TOKENID}" \
    --data-urlencode "propagate=1" >/dev/null 2>&1 || true

cat >&2 <<EOF

[✓] least-privilege token provisioned.

    export it into your secrets manager / CI, then:

      export PVE_TOKEN="${TOKENID}=${SECRET}"

    ^ shown ONCE. PVE will never reveal this secret again.

    identity : ${SVC_USER}      (dedicated, not root)
    token    : ${TOKENID}       (privsep=1, expires in ${TTL_DAYS} days)
    role     : ${ROLE}          (${PRIVS})
    scope    : /pool/${POOL}, /storage/${STORAGE}, /sdn/zones  (NOT '/')

    rotate/revoke:  sh $0 --revoke
EOF
