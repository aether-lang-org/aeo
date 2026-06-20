#!/bin/sh
# Provision bhyve prerequisites for test/real_bhyve.ae on FreeBSD. Loads
# the vmm kernel module, installs the UEFI bootrom (pkg bhyve-firmware),
# and creates a small empty disk image. Root required.
#
#   sudo sh test/setup-bhyve.sh
#   sudo /tmp/real_bhyve              # then run the test
#   sudo sh test/setup-bhyve.sh --teardown
#
# This stands in for an operator's host setup — aeo drives bhyve once the
# module, firmware, and a disk image exist. A real GUEST (bootable OS +
# tap/bridge networking) is a further step exercised on a full-VM host.
set -eu

IMG="/zroot/images/aeo-vm1.raw"
FW="/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"

if [ "${1:-}" = "--teardown" ]; then
    bhyvectl --vm=aeo-vm1 --destroy 2>/dev/null || true
    rm -f "$IMG"
    echo "torn down aeo-vm1 + image"
    exit 0
fi

# 1. vmm kernel module (provides /dev/vmm).
if ! kldstat -q -m vmm; then
    kldload vmm
    echo "loaded vmm.ko"
fi

# 2. UEFI bootrom — lets bhyve boot a disk directly, no bhyveload.
if [ ! -f "$FW" ]; then
    echo "installing bhyve-firmware (provides $FW)..."
    pkg install -y bhyve-firmware
fi

# 3. A small empty disk image. With no bootable OS the guest lands at the
#    UEFI shell — enough to exercise aeo's spawn/probe(process-alive)/
#    destroy lifecycle against real bhyve/bhyvectl.
mkdir -p /zroot/images
if [ ! -f "$IMG" ]; then
    truncate -s 1G "$IMG"
    echo "created $IMG (1G empty)"
fi

echo "bhyve prereqs ready. now: sudo /tmp/real_bhyve"
