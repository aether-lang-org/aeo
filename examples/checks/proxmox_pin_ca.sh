#!/bin/sh
# proxmox_pin_ca.sh — courier PVE's own CA cert back to the orchestrator, so the
# driver can PIN it for all 8006 calls (verify against THAT cert, not the public
# chain and not blind-trust). The "1970s inter-bank courier" applied to TLS: ssh
# hand-delivers the trust anchor ONCE; the standing HTTPS channel is verified
# against it thereafter.
#
# WHY: PVE ships a PRIVATE CA (/etc/pve/pve-root-ca.pem) — no public root. For M2M
# orchestration we don't want browser trust chains; we want to pin exactly that CA.
# Without this, driver_proxmox falls back to set_insecure(1) (accept any cert) — a
# MITM hole. With it, the driver does set_cafile + verify (fail-closed).
#
# Usage:
#   PVE_SSH=root@192.168.0.204 sh proxmox_pin_ca.sh              # -> ./pve-root-ca.pem
#   PVE_SSH=root@192.168.0.204 OUT=/etc/aeo/pve-ca.pem sh proxmox_pin_ca.sh
#
# Then export the path for the driver:
#   export AEO_PVE_CACERT="$(pwd)/pve-root-ca.pem"
#   aeo up examples/silly_addition_proxmox.ae     # now pins + verifies 8006
set -eu

PVE_SSH="${PVE_SSH:?set PVE_SSH=root@<pve-host>}"
OUT="${OUT:-pve-root-ca.pem}"
CA_REMOTE="${CA_REMOTE:-/etc/pve/pve-root-ca.pem}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 ${PVE_SSH}"

echo "[*] couriering ${CA_REMOTE} from ${PVE_SSH} -> ${OUT}…" >&2
$SSH "cat ${CA_REMOTE}" > "$OUT"

# sanity: it must be a real CA cert.
if ! openssl x509 -in "$OUT" -noout -subject >/dev/null 2>&1; then
    echo "  ERROR: ${OUT} is not a valid PEM cert (courier failed?)"; rm -f "$OUT"; exit 1
fi
SUBJ=$(openssl x509 -in "$OUT" -noout -subject 2>/dev/null | sed 's/^subject=//')
FPR=$(openssl x509 -in "$OUT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

cat >&2 <<EOF
[✓] pinned CA couriered to ${OUT}
    subject : ${SUBJ}
    sha256  : ${FPR}

    export it so driver_proxmox pins + verifies 8006 (drops the accept-any fallback):

      export AEO_PVE_CACERT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

    then \`aeo up/check/down\` verify every 8006 call against this exact cert. A
    wrong/tampered cert on 8006 -> handshake fails closed (never silently trusted).
EOF
