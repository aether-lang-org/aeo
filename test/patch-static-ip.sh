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
#   sudo sh test/patch-static-ip.sh <vm-name> [ip]   # default ip 172.16.0.50
#
# Needs sudo: mdconfig, gpart, fuse-ext2, cp, mount/umount.
set -eu

VM="${1:?usage: patch-static-ip.sh <vm-name> [ip]}"
IP="${2:-172.16.0.50}"
GW="172.16.0.1"
DISK="/zroot/vm/$VM/disk0.img"
MNT="/tmp/${VM}-disk"

[ -f "$DISK" ] || { echo "no disk $DISK (is $VM provisioned?)"; exit 1; }
vm stop "$VM" 2>/dev/null || true; sleep 3

MD=$(mdconfig -a -t vnode -f "$DISK")
trap 'umount "$MNT" 2>/dev/null; mdconfig -d -u "$MD" 2>/dev/null' EXIT
mkdir -p "$MNT"
fuse-ext2 "/dev/${MD}p1" "$MNT" -o rw+

# A clean, valid netplan. match by name e* so it works regardless of NIC
# naming / MAC. Plus disable cloud-init's own network management so it
# doesn't fight this.
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
cp /tmp/99-aeo-static.yaml "$MNT/etc/netplan/99-aeo-static.yaml"
chmod 600 "$MNT/etc/netplan/99-aeo-static.yaml"
echo "network: {config: disabled}" > /tmp/99-disable-net.cfg
cp /tmp/99-disable-net.cfg "$MNT/etc/cloud/cloud.cfg.d/99-disable-network.cfg"

sync; umount "$MNT"; mdconfig -d -u "$MD"; trap - EXIT
echo "patched $VM with static $IP. Start it:  sudo vm start $VM"
echo "then:  ssh -i ~/.ssh/id_rsa ubuntu@$IP"
