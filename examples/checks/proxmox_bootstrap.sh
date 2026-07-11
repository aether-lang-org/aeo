#!/bin/sh
# proxmox_bootstrap.sh — one-time PREPARATION of a fresh PVE host for aeo, over ssh.
#
# A bare Proxmox box ships none of what a proxmox_vm deploy needs. This script does
# the ONE-TIME host setup (the four steps that were hand-done during bring-up), so a
# fresh orchestrator (Chromebook or other) can then just `aeo up`:
#
#   1. TEMPLATE   — download a Debian 12 cloud image + build the cloud-init template
#                   (the exact `qm` sequence proven live). Skipped if it already exists.
#   2. POOL       — ensure aeo's resource pool exists and the TEMPLATE IS A MEMBER of
#                   it — a least-priv token can only clone a pool-member template.
#   3. SNIPPET    — enable `snippets` content on the storage + place the aeo cloud-init
#                   user-data (the doer snippet) as local:snippets/aeo-agent-init.yaml.
#   4. (implicit) — leaves the box ready; the operator then runs proxmox_token_setup.sh
#                   (least-priv token) and proxmox_pin_ca.sh (courier the CA), and deploys.
#
# WHY ssh (not 8006): template creation, snippet placement, and pool ops are host-shell
# / admin operations. 8006 has no host-shell endpoint and the deploy token is 403 on the
# host by design. This runs as root over ssh — the same higher-priv channel used for the
# host-agent install. It touches ONLY aeo's own template/pool/snippet; nothing else.
#
# Usage:
#   PVE_SSH=root@192.168.0.204 sh proxmox_bootstrap.sh
#   PVE_SSH=root@192.168.0.204 sh proxmox_bootstrap.sh --uninstall   # remove template+pool+snippet
#
# Env knobs:
#   PVE_SSH        ssh target (root@host). Required.
#   PVE_POOL       aeo pool name (default aeo-prod — matches proxmox_token_setup.sh).
#   PVE_STORAGE    storage for the template disk (default local-lvm).
#   PVE_SNIP_STORE storage that holds snippets (default local).
#   TEMPLATE_ID    VMID for the template (default 9000).
#   TEMPLATE_NAME  its name (default debian-12-cloudinit — must match the composition's template()).
#   IMAGE_URL      the cloud image (default Debian 12 genericcloud amd64).
#   SNIPPET_SRC    local path to the cloud-init snippet (default the repo's proxmox_cloudinit.yaml).
set -eu

PVE_SSH="${PVE_SSH:?set PVE_SSH=root@<pve-host>}"
POOL="${PVE_POOL:-aeo-prod}"
STORAGE="${PVE_STORAGE:-local-lvm}"
SNIP_STORE="${PVE_SNIP_STORE:-local}"
TID="${TEMPLATE_ID:-9000}"
TNAME="${TEMPLATE_NAME:-debian-12-cloudinit}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SNIPPET_SRC="${SNIPPET_SRC:-$SCRIPT_DIR/proxmox_cloudinit.yaml}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 ${PVE_SSH}"

if [ "${1:-}" = "--uninstall" ]; then
    echo "[*] removing aeo template ${TID}, pool ${POOL}, snippet…" >&2
    $SSH "qm destroy ${TID} --purge 2>/dev/null || true
          pvesh delete /pools/${POOL} 2>/dev/null || true
          rm -f /var/lib/vz/snippets/aeo-agent-init.yaml 2>/dev/null || true
          echo '  removed (template + pool + snippet).'"
    exit 0
fi

# ---- 1. TEMPLATE (idempotent: skip if VMID TID is already a template) ----------
echo "[*] template ${TID} (${TNAME})…" >&2
$SSH "TID='${TID}' TNAME='${TNAME}' STORAGE='${STORAGE}' IMAGE_URL='${IMAGE_URL}' sh -s" <<'REMOTE'
set -eu
if qm config "$TID" >/dev/null 2>&1; then
    echo "  VMID $TID already exists — leaving it (delete with --uninstall to rebuild)."
    exit 0
fi
img="/var/lib/vz/template/${TNAME}.qcow2"
if [ ! -f "$img" ]; then
    echo "  downloading $IMAGE_URL…"
    curl -fsSL "$IMAGE_URL" -o "$img"
fi
qemu-img info "$img" >/dev/null 2>&1 || { echo "  BAD image download"; rm -f "$img"; exit 1; }
# the proven qm sequence (matches the live-built template exactly).
qm create "$TID" --name "$TNAME" --memory 2048 --cores 2 \
   --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
qm set "$TID" --scsi0 "${STORAGE}:0,import-from=${img}"
qm set "$TID" --ide2  "${STORAGE}:cloudinit"
qm set "$TID" --boot order=scsi0
qm set "$TID" --serial0 socket --vga serial0
qm set "$TID" --agent enabled=1
qm template "$TID"
echo "  template $TID built."
REMOTE

# ---- 2. POOL + template membership (least-priv token clones only pool members) --
echo "[*] pool ${POOL} + template membership…" >&2
$SSH "POOL='${POOL}' TID='${TID}' sh -s" <<'REMOTE'
set -eu
pvesh get "/pools/${POOL}" >/dev/null 2>&1 || pvesh create /pools --poolid "${POOL}" --comment "aeo-managed" >/dev/null
pvesh set "/pools/${POOL}" --vms "${TID}" >/dev/null 2>&1 || true
echo "  ${TID} is a member of pool ${POOL}."
REMOTE

# ---- 3. SNIPPET: enable snippets content + place the doer cloud-init ------------
echo "[*] snippet storage + doer cloud-init…" >&2
[ -f "$SNIPPET_SRC" ] || { echo "  MISSING snippet source: $SNIPPET_SRC"; exit 1; }
# enable snippets content on the storage (keeps existing content types).
$SSH "SNIP_STORE='${SNIP_STORE}' sh -s" <<'REMOTE'
set -eu
cur=$(pvesm status -storage "$SNIP_STORE" 2>/dev/null | awk 'NR==2{print $2}')
# best-effort: add snippets to whatever content the store already serves.
pvesm set "$SNIP_STORE" --content iso,vztmpl,backup,snippets 2>/dev/null || \
  pvesm set "$SNIP_STORE" --content snippets 2>/dev/null || true
mkdir -p /var/lib/vz/snippets
echo "  snippets enabled on $SNIP_STORE."
REMOTE
# place the snippet (scp).
scp -o StrictHostKeyChecking=accept-new "$SNIPPET_SRC" \
    "${PVE_SSH}:/var/lib/vz/snippets/aeo-agent-init.yaml" >/dev/null
echo "  placed $SNIPPET_SRC -> local:snippets/aeo-agent-init.yaml" >&2

cat >&2 <<EOF

[✓] PVE host bootstrapped for aeo.

    template : ${TNAME} (VMID ${TID}) — member of pool ${POOL}
    snippet  : local:snippets/aeo-agent-init.yaml

    NEXT (the fresh-orchestrator sequence — run token_setup AFTER this):
      1. sh proxmox_token_setup.sh              # least-priv token -> export PVE_TOKEN
      2. sh proxmox_pin_ca.sh                   # courier PVE CA   -> export AEO_PVE_CACERT
      3. aeo up examples/silly_addition_proxmox.ae

    ORDER MATTERS: this bootstrap creates pool '${POOL}'. The token's ACL is granted
    ON that pool by proxmox_token_setup.sh, so token_setup MUST run after (or be
    re-run after) this — if the pool is (re)created after the token was set, the
    token's pool ACL is orphaned and it sees no template (clone -> "not visible").
    proxmox_token_setup.sh is idempotent; just re-run it (it re-grants + rotates).

    tear down this bootstrap:  PVE_SSH=${PVE_SSH} sh $0 --uninstall
EOF
