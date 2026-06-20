#!/bin/sh
# setup-nat.sh — one-time: put the bhyve guest network in NAT mode.
#
# WHY: bridged-to-LAN networking on this box is non-deterministic — the
# guest sends DHCP but the reply never comes back to its tap
# (netstat tap0: in=6000+ out=0), almost certainly the upstream LAN switch
# limiting MACs per port. NAT sidesteps L2-to-LAN entirely: the guest sits
# on a private net (172.16.0.0/24) with the host as gateway + a LOCAL
# dnsmasq DHCP, and the host NATs it out. The guest's DHCP never touches the
# LAN switch, so it's reliable. The host reaches the guest directly on the
# private net (ssh + curl still work); expose(port) becomes a host forward.
#
#   sudo sh test/setup-nat.sh            # one-time host NAT plumbing
#   sudo sh test/setup-nat.sh --check    # show NAT state
#
# After this, aeo's bhyve driver puts guests on the `aeonat` switch.
set -eu

SW="aeonat"
NET="172.16.0.0/24"
GW="172.16.0.1/24"
EXT="re0"

if [ "${1:-}" = "--check" ]; then
    vm switch list
    echo "--- forwarding ---"; sysctl net.inet.ip.forwarding
    echo "--- pf nat ---"; pfctl -s nat 2>/dev/null | head
    echo "--- dnsmasq ---"; service dnsmasq status 2>&1 | head -1; ps ax | grep '[d]nsmasq' | head -1
    exit 0
fi

# 1. dnsmasq (local DHCP+DNS for the NAT net).
pkg info -e dnsmasq >/dev/null 2>&1 || pkg install -y dnsmasq

# 2. IP forwarding (so NAT routes), persistent.
sysctl net.inet.ip.forwarding=1
sysrc gateway_enable="YES"

# 3. pf NAT: source-NAT the private net out the external IF.
cat > /etc/pf.conf <<EOF
ext_if = "$EXT"
nat on \$ext_if from ${NET} to any -> (\$ext_if)
pass all
EOF
sysrc pf_enable="YES"
service pf restart 2>&1 | tail -1 || service pf start 2>&1 | tail -1

# 4. the vm-bhyve NAT switch (gateway address + nat on).
vm switch list | awk '{print $1}' | grep -qx "$SW" || vm switch create "$SW"
vm switch address "$SW" "$GW"
vm switch nat "$SW" on

# 5. dnsmasq DHCP on the NAT bridge (vm-<switch>).
cat > /usr/local/etc/dnsmasq.conf <<EOF
interface=vm-${SW}
bind-interfaces
dhcp-range=172.16.0.10,172.16.0.250,12h
dhcp-option=3,172.16.0.1
dhcp-option=6,8.8.8.8
EOF
sysrc dnsmasq_enable="YES"
service dnsmasq restart 2>&1 | tail -1 || service dnsmasq start 2>&1 | tail -1

# 6. a `linux-nat` template (the linux template, but on the NAT switch) so
#    aeo's driver creates guests on the NAT net via `vm create -t linux-nat`.
if [ ! -f /zroot/vm/.templates/linux-nat.conf ]; then
    sed "s/network0_switch=.*/network0_switch=\"$SW\"/" \
        /zroot/vm/.templates/linux.conf > /zroot/vm/.templates/linux-nat.conf
    grep -q "network0_switch" /zroot/vm/.templates/linux-nat.conf || \
        echo "network0_switch=\"$SW\"" >> /zroot/vm/.templates/linux-nat.conf
    echo "created template linux-nat (switch=$SW)"
fi

echo ""
echo "NAT ready. Guests on switch '$SW' get a 172.16.0.x lease from local"
echo "dnsmasq and NAT out via $EXT. aeo's bhyve driver now uses this switch."
echo "Check:  sudo sh test/setup-nat.sh --check"
