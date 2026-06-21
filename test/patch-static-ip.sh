#!/bin/sh
# patch-static-ip.sh — give a guest a CLEAN static IP by writing a valid
# netplan directly into its disk (offline). Sidesteps both the
# DHCP-broadcast issue (dnsmasq never sees the guest's DHCP on the bridge)
# AND the trap that bit us: sed-editing the cloud-init seed's network-config
# produced schema-INVALID YAML, so cloud-init REJECTED it
# (console: "cloud-config failed schema validation!") and the guest came up
# with no IPv4 -> systemd "Wait for Network" hangs forever.
#
# Writing a clean netplan file straight into /etc/netplan/ avoids the
# seed/cloud-init schema path entirely.
#
#   sh test/patch-static-ip.sh <vm-name> [ip]    # default ip 172.16.0.50
#
# Runs as a NORMAL user: each privileged op uses `sudo -n` (so aeo's bhyve
# driver can invoke it directly — there is no NOPASSWD for /bin/sh). Needs
# NOPASSWD sudo for: vm, mdconfig, gpart, fuse-ext2, cp, mount/umount.
set -eu

VM="${1:?usage: patch-static-ip.sh <vm-name> [ip]}"
IP="${2:-172.16.0.50}"
GW="172.16.0.1"
DISK="/zroot/vm/$VM/disk0.img"
MNT="/tmp/${VM}-disk"

[ -f "$DISK" ] || { echo "no disk $DISK (is $VM provisioned?)"; exit 1; }
sudo -n vm stop "$VM" 2>/dev/null || true; sleep 3

MD=$(sudo -n mdconfig -a -t vnode -f "$DISK")
trap 'sudo -n umount "$MNT" 2>/dev/null; sudo -n mdconfig -d -u "$MD" 2>/dev/null' EXIT
mkdir -p "$MNT"
sudo -n fuse-ext2 "/dev/${MD}p1" "$MNT" -o rw+

# A clean, valid netplan. match by name e* so it works regardless of NIC
# naming / MAC. Plus disable cloud-init's own network management so it
# doesn't fight this. Build the files in /tmp (user-writable), then sudo cp
# them into the root-owned guest filesystem.
cat > /tmp/99-aeo-static.yaml <<EOF
network:
  version: 2
  ethernets:
    aeonic:
      match:
        name: "e*"
      dhcp4: false
      addresses: [$IP/24]
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$GW]
EOF
sudo -n cp /tmp/99-aeo-static.yaml "$MNT/etc/netplan/99-aeo-static.yaml"
echo "network: {config: disabled}" > /tmp/99-disable-net.cfg
sudo -n cp /tmp/99-disable-net.cfg "$MNT/etc/cloud/cloud.cfg.d/99-disable-network.cfg"

sync; sudo -n umount "$MNT"; sudo -n mdconfig -d -u "$MD"; trap - EXIT
echo "patched $VM with static $IP"
