#!/bin/sh
# setup-guest.sh — one-time: fetch an Alpine Linux cloud image, create a
# bhyve VM from it via vm-bhyve with cloud-init (ssh key injected), and
# start it. After this, aeo's bhyve driver drives the VM (start/stop) and
# reaches the guest over ssh. Root required (vm-bhyve needs root).
#
#   sudo sh test/setup-guest.sh            # provision + start the guest
#   sudo sh test/setup-guest.sh --status   # show vm list + guest IP
#   sudo sh test/setup-guest.sh --destroy  # tear the guest down
#
# Uses the x86_64 UEFI cloud-init Alpine image (matches the vm-bhyve
# `linux` template's loader="uefi"). cloud-init installs the host user's
# ssh pubkey so aeo can ssh in to install/run aeo-agent + the Python app.
#
# This is the per-BASE-IMAGE one-time step. Per-VM create/start is then
# aeo's job (the bhyve driver shells to `vm`).
set -eu

VM="aeo-guest"
IMG_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.0-x86_64-uefi-cloudinit-metal-r0.qcow2"
IMG_FILE="nocloud_alpine-3.20.0-x86_64-uefi-cloudinit-metal-r0.qcow2"
PUBKEY="${PUBKEY:-/home/paul/.ssh/id_rsa.pub}"

case "${1:-}" in
--destroy)
    vm stop "$VM" 2>/dev/null || true
    sleep 2
    vm destroy -f "$VM" 2>/dev/null || true
    echo "destroyed $VM"
    exit 0
    ;;
--status)
    vm list
    echo "--- guest IP (from vm-bhyve dhcp lease / arp) ---"
    vm info "$VM" 2>/dev/null | grep -iE "name|state|ip" || true
    exit 0
    ;;
esac

# 1. Fetch the cloud image into the vm-bhyve image store (idempotent).
if ! vm img | grep -q "$IMG_FILE"; then
    echo "fetching Alpine UEFI cloud image (~50MB)..."
    vm img "$IMG_URL"
fi

# 2. Create the guest from the image with cloud-init + ssh key. The
#    `linux` template is UEFI + virtio + the `public` switch (wired bridge).
if ! vm list | awk '{print $1}' | grep -qx "$VM"; then
    echo "creating $VM from image with cloud-init ssh key..."
    vm create -t linux -i "$IMG_FILE" -C -k "$PUBKEY" "$VM"
fi

# 3. Start it.
vm start "$VM"
echo ""
echo "started $VM. Give it ~30-60s to boot + cloud-init, then:"
echo "  sudo sh test/setup-guest.sh --status      # find its IP"
echo "  ssh alpine@<ip>                            # cloud-init user (key auth)"
echo ""
echo "Once it has an IP, aeo's bhyve driver can drive it and we install"
echo "aeo-agent + the Python /add service inside it."
