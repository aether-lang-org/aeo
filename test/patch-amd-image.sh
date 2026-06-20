#!/bin/sh
# patch-amd-image.sh — bake AMD-Ryzen-safe kernel params into the Ubuntu
# cloud image's GRUB, OFFLINE (host-side), producing jammy-amd.img.
#
# WHY: Ubuntu Linux guests hang very early in boot under bhyve on this AMD
# Ryzen box (intermittent; guest barely transmits, never networks). Root
# cause: AMD TSC/clocksource handling in virtualization (+ bhyve not
# persisting UEFI vars). Fix = AMD-safe kernel cmdline. It must be on the
# cmdline from the FIRST boot — cloud-init can only fix the NEXT boot
# (chicken/egg) — so we patch the image's GRUB offline before any boot.
#
# Confirmed: with this patch the guest boots far enough to send DHCP
# (vs hanging at ~20 packets on the stock image).
#
#   sudo sh test/patch-amd-image.sh         # build jammy-amd.img (once)
#
# Needs sudo: qemu-img, mdconfig, gpart, fuse-ext2, mount/umount, sed.
set -eu

IMGDIR="/zroot/vm/.img"
SRC="$IMGDIR/jammy-server-cloudimg-amd64.img"   # stock qcow2 cloud image
RAW="$IMGDIR/jammy-patched.raw"
OUT="$IMGDIR/jammy-amd.img"                      # the AMD-safe result
MNT="/tmp/jammy-patch"
AMD="clocksource=hpet tsc=unstable processor.max_cstate=5 idle=halt"

[ -f "$SRC" ] || { echo "missing $SRC (run: vm img <ubuntu-url> first)"; exit 1; }

echo "1. qcow2 -> raw"
qemu-img convert -f qcow2 -O raw "$SRC" "$RAW"

echo "2. attach as md + find ext4 root"
MD=$(mdconfig -a -t vnode -f "$RAW")            # e.g. md0
trap 'umount "$MNT" 2>/dev/null; mdconfig -d -u "$MD" 2>/dev/null' EXIT
gpart show "$MD" | grep -q linux-data || { echo "no linux-data partition"; exit 1; }
ROOT="/dev/${MD}p1"                              # p1 = linux-data (root)

echo "3. mount $ROOT (fuse-ext2 rw)"
mkdir -p "$MNT"
fuse-ext2 "$ROOT" "$MNT" -o rw+

echo "4. inject AMD params into GRUB"
# /etc/default/grub (for future update-grub inside the guest)
sed -i '' "s|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$AMD console=ttyS0\"|" "$MNT/etc/default/grub"
sed -i '' "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"$AMD\"|" "$MNT/etc/default/grub"
# the LIVE grub.cfg (what actually boots on the FIRST boot)
sed -i '' "s|console=tty1 console=ttyS0|console=tty1 console=ttyS0 $AMD|g" "$MNT/boot/grub/grub.cfg"
grep -q "$AMD" "$MNT/boot/grub/grub.cfg" || { echo "grub.cfg patch failed"; exit 1; }

echo "5. unmount + detach + repackage to qcow2"
sync; umount "$MNT"; mdconfig -d -u "$MD"; trap - EXIT
qemu-img convert -f raw -O qcow2 "$RAW" "$OUT"
rm -f "$RAW"

echo ""
echo "Built $OUT (AMD-safe). The bhyve driver provisions guests from this."
echo "Verify a guest: boot it, then  ssh ubuntu@<ip> 'cat /proc/cmdline'"
echo "  -> should show: $AMD"
