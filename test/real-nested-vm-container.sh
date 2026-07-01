#!/bin/sh
# real-nested-vm-container.sh — the REAL nested-agent proof, on actual KVM.
# NOT a localhost mock: grandparent -> parent -> child across TWO real boundaries.
#
#   grandparent = aeo/this script on the HOST
#     └─ parent = aeo-agent resident in a real KVM guest   (across the VM NIC)
#          └─ child = aeo-agent in a real podman container  (across the ctr boundary)
#             nested INSIDE that guest
#
# Run ON the bazzite box (has KVM + the built agent). Assumes:
#   - ~/aeo-images/debian-genericcloud.qcow2 (pristine Debian 12 cloud image)
#   - ~/aeo-build/aeo/aeo-agent (glibc build; Debian guest runs it unmodified)
#   - the guest VM lifecycle traps are handled (systemd-run so it survives ssh
#     logout; agent binds 0.0.0.0 so it's reachable from outside its guest) —
#     see memory real-kvm-agent-proof-bazzite.
#
# This is the manual, reproducible form of the proof done live 2026-07-01. It
# boots the guest, injects the agent, starts parent (in guest) + child (in a
# container in the guest), then drives the whole chain FROM THE HOST and asserts
# the child's report relays all the way up. Boots are NOOP (proves the
# orchestration tree converges across real boundaries, not that a workload ran).
set -eu

TOK="courier-nested-$$"
IMG="$HOME/aeo-images/debian-genericcloud.qcow2"
WORK="$HOME/aeo-images/vm-parent.qcow2"
AGENT="$HOME/aeo-build/aeo/aeo-agent"
SSHG="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 debian@127.0.0.1"
SCPG="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222"

echo "=== 1. fresh guest disk + boot via systemd-run (survives logout) ==="
systemctl --user stop aeo-vm-parent 2>/dev/null || true
rm -f "$WORK"; qemu-img create -f qcow2 -F qcow2 -b "$IMG" "$WORK" 6G >/dev/null
KEY=$(cat "$HOME/.ssh/id_rsa.pub")
mkdir -p /tmp/seed
printf 'instance-id: vm-parent\nlocal-hostname: vm-parent\n' > /tmp/seed/meta-data
printf '#cloud-config\npassword: aeo\nchpasswd: { expire: false }\nssh_pwauth: true\nssh_authorized_keys:\n  - %s\n' "$KEY" > /tmp/seed/user-data
mkisofs -o /tmp/seed.iso -V cidata -J -r /tmp/seed/meta-data /tmp/seed/user-data 2>/dev/null
systemd-run --user --unit=aeo-vm-parent \
  qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
  -drive file="$WORK",if=virtio \
  -drive file=/tmp/seed.iso,if=virtio,media=cdrom \
  -display none -serial file:/tmp/parent-console.log \
  -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::2223-:9450 \
  -device virtio-net-pci,netdev=n0 >/dev/null

echo "=== 2. wait for guest ssh ==="
until $SSHG "true" 2>/dev/null; do sleep 3; done
ssh-keygen -R "[127.0.0.1]:2222" >/dev/null 2>&1 || true

echo "=== 3. inject agent; install podman in guest (VERIFY it lands) ==="
$SCPG "$AGENT" debian@127.0.0.1:/tmp/aeo-agent >/dev/null 2>&1
$SSHG "chmod +x /tmp/aeo-agent" 2>/dev/null
if ! $SSHG "which podman" 2>/dev/null | grep -q podman; then
    echo "  podman missing on fresh disk — installing (apt update first) ..."
    $SSHG "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman" >/dev/null 2>&1 || true
fi
# Fail LOUD if podman still isn't there — don't silently continue to a false
# 'unreachable' later (this bit the first consolidated run: fresh disk wiped
# podman, the install was skipped, child never started).
$SSHG "which podman >/dev/null 2>&1 && podman --version" 2>/dev/null | grep -q podman \
    || { echo "FAIL: podman not available in guest (image egress? apt failed?)"; exit 1; }
echo "  podman ready in guest"

echo "=== 4. start CHILD agent in a podman container in the guest (:9451) ==="
$SSHG "podman rm -f aeo-child 2>/dev/null >/dev/null; podman run -d --name aeo-child -p 9451:9451 -v /tmp/aeo-agent:/aeo-agent:ro -e AEO_TRANSPORT=http -e AEO_PORT=9451 -e AEO_NODE=child -e AEO_TOKEN=$TOK -e AEO_BIND=0.0.0.0 -e AEO_BOOT_NOOP=1 docker.io/library/debian:stable-slim /aeo-agent >/dev/null 2>&1" 2>/dev/null
# Wait for the CHILD to actually be listening (a cold pull + first run is slow;
# a fixed sleep is a flake) — poll its /health FROM THE GUEST until it answers.
echo "  waiting for child container to listen on :9451 ..."
$SSHG "for i in \$(seq 1 30); do curl -fsS http://127.0.0.1:9451/health >/dev/null 2>&1 && { echo child-listening; break; }; sleep 2; done" 2>/dev/null

echo "=== 5. start PARENT agent in the guest (:9450), courier the child's port ==="
$SSHG "OLD=\$(ss -ltnp 2>/dev/null | grep ':9450 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2); [ -n \"\$OLD\" ] && kill -9 \$OLD 2>/dev/null; sleep 1; AEO_TRANSPORT=http AEO_PORT=9450 AEO_NODE=parent AEO_TOKEN=$TOK AEO_BIND=0.0.0.0 AEO_BOOT_NOOP=1 AEO_PORT_child=9451 setsid nohup /tmp/aeo-agent >/tmp/agent-parent.log 2>&1 &" 2>/dev/null
# Wait for the parent to be reachable FROM THE HOST (across the VM NIC) before driving it.
until curl -fsS http://127.0.0.1:2223/health >/dev/null 2>&1; do sleep 1; done
echo "parent-listening"

echo "=== 6. THE CHAIN, driven FROM THE HOST (host:2223 -> guest:9450) ==="
fail=0
h=$(curl -s http://127.0.0.1:2223/health)
[ "$h" = "ok" ] && echo "PASS host->parent /health across VM NIC" || { echo "FAIL /health -> '$h'"; fail=1; }
r=$(curl -s -X POST --data "delegate $TOK child" http://127.0.0.1:2223/dispatch)
[ "$r" = "report $TOK child up" ] \
  && echo "PASS host->parent DELEGATE child -> '$r'  (two real boundaries!)" \
  || { echo "FAIL delegate -> '$r' (want 'report $TOK child up')"; fail=1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data "delegate BAD child" http://127.0.0.1:2223/dispatch)
[ "$code" = "401" ] && echo "PASS wrong-token -> 401 (auth across the whole chain)" || { echo "FAIL wrong-token -> $code"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: REAL nested chain converged — grandparent(host) -> parent(VM) -> child(container-in-VM)"
  exit 0
fi
echo "FAIL: real nested chain"; exit 1
