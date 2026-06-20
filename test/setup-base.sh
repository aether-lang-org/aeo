#!/bin/sh
# setup-base.sh — build the GOLDEN base image ONCE, so every VM is a fast
# ZFS clone instead of a ~3-minute provision-from-scratch.
#
# Runs on the FreeBSD host (needs root via NOPASSWD sudo for vm/zfs). It:
#   1. provisions an `aeo-base` Ubuntu guest from the cloud image, with
#      cloud-init installing podman + pre-pulling the python:alpine base
#      image (and, later, aeo-agent),
#   2. lets it finish first-boot,
#   3. snapshots it: `vm snapshot aeo-base@golden`.
#
# After that, aeo's bhyve driver clones aeo-base@golden for each VM
# (vm clone = copy-on-write, ~seconds, boots an already-warm guest: no
# cloud-init first-boot stall, no apt, no image pull). That's the speed
# unlock — slow provisioning happens once, not per `aeo up`.
#
#   sudo sh test/setup-base.sh           # build the golden image (once)
#   sudo sh test/setup-base.sh --resnap  # re-snapshot after updating aeo-base
#   sudo sh test/setup-base.sh --destroy # remove base + snapshot
set -eu

BASE="aeo-base"
IMG="jammy-server-cloudimg-amd64.img"
URL="https://cloud-images.ubuntu.com/jammy/current/$IMG"
KEY="${KEY:-/home/paul/.ssh/id_rsa.pub}"

case "${1:-}" in
--destroy)
    vm stop "$BASE" 2>/dev/null || true; sleep 3
    vm destroy -f "$BASE" 2>/dev/null || true
    echo "destroyed $BASE (+ its golden snapshot)"
    exit 0
    ;;
--resnap)
    # Golden-image hygiene: a clone must re-initialize its identity +
    # networking, else it inherits the base's machine-id/cloud-init state
    # and never DHCPs (verified). Clean cloud-init + machine-id INSIDE the
    # running base over ssh, THEN stop + snapshot. After this, each clone
    # re-runs cloud-init on first boot → fresh machine-id → fresh DHCP.
    echo "cleaning base identity for cloning (cloud-init + machine-id)..."
    MAC=$(grep -o 'network0_mac="[^"]*"' "/zroot/vm/$BASE/$BASE.conf" | cut -d'"' -f2)
    for n in $(seq 200 254); do ping -c1 -W1 192.168.0.$n >/dev/null 2>&1; done
    BIP=$(arp -a 2>/dev/null | grep -i "$MAC" | grep -oE '192.168.0.[0-9]+' | head -1)
    if [ -n "$BIP" ]; then
        ssh -i /home/paul/.ssh/id_rsa -o StrictHostKeyChecking=no ubuntu@"$BIP" \
          'sudo cloud-init clean --logs 2>/dev/null; sudo truncate -s0 /etc/machine-id; sudo rm -f /var/lib/dbus/machine-id /etc/netplan/50-cloud-init.yaml; sudo rm -rf /var/lib/cloud/instances/* 2>/dev/null; sync' \
          2>&1 | tail -2
    else
        echo "WARN: base has no IP; cleaning via console not automated — clones may not network"
    fi
    vm stop "$BASE" 2>/dev/null || true; sleep 3
    for i in $(seq 1 15); do sleep 2; vm list 2>/dev/null | grep -qE "$BASE.*[Ss]topped" && break; done
    vm snapshot -f "$BASE@golden"
    echo "re-snapshotted $BASE@golden (clones will re-init networking)"
    exit 0
    ;;
esac

# Fetch the cloud image once.
vm img 2>/dev/null | grep -q "$IMG" || vm img "$URL"

# Provision the base with podman + pre-pulled python image, key, auto-net.
KEYV=$(cat "$KEY")
cat > /tmp/aeo-base-ud.yml <<YAML
#cloud-config
datasource_list: [ NoCloud, None ]
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    ubuntu:aeo
    root:aeo
ssh_authorized_keys:
  - $KEYV
package_update: true
packages:
  - podman
runcmd:
  - [ sh, -c, "for i in \$(ls /sys/class/net | grep -v lo); do ip link set \$i up; done; dhclient || true" ]
  - [ sh, -c, "podman pull docker.io/library/python:3-alpine || true" ]
YAML

if ! vm list | awk '{print $1}' | grep -qx "$BASE"; then
    vm create -t linux -i "$IMG" -c 2 -m 2G -C -u /tmp/aeo-base-ud.yml "$BASE"
fi
vm start "$BASE"

echo "base $BASE booting + provisioning (podman + python image). Wait ~3 min for"
echo "cloud-init + the image pull to finish, then snapshot:"
echo "  sudo sh test/setup-base.sh --resnap     # (stops base + snapshots @golden)"
echo ""
echo "After that, every 'aeo up' with a bhyve_vm clones aeo-base@golden — fast."
