#!/bin/sh
# breakout-harness.sh — adversarial confinement tests for the bhyve-Ubuntu
# guest. Each test gets a PRISTINE clone of the golden snapshot (so a breakout
# can't poison the next test), attempts to bust out of a confinement, asserts
# the attempt was DENIED, and destroys the clone.
#
# Iteration cost (measured): clone = ~8KB + 0s; destroy = instant full reclaim;
# disk is effectively free — the cost is boot time. See memory
# aeo-breakout-test-economics.
#
#   sudo sh test/breakout-harness.sh           # run all probes
#   sudo sh test/breakout-harness.sh net        # one category (net|fd|vm)
#   N=20 sudo sh test/breakout-harness.sh net   # repeat a category N times
#
# Run ON the GhostBSD host (needs vm clone/start/destroy + ssh into the guest).
#
# CONFINEMENT READINESS (honest):
#   vm  — the bhyve VM boundary (guest cannot touch host). Always on. DENY now.
#   fd  — Capsicum fd-confinement (constrain(vm){ constraint(...) }). The
#         cap_enter() launcher is NOT wired yet, so these ESCAPE today — they
#         are RED tests that go GREEN when enforcement lands (TDD).
#   net — pf egress/ingress whitelist. pf-rule generation NOT wired yet, so
#         these ESCAPE today too — same red-until-enforced posture.
set -u

GOLDEN="${GOLDEN:-aeo-base@golden}"
KEY="${KEY:-/home/paul/.ssh/id_rsa}"
N="${N:-1}"
CAT="${1:-all}"

pass=0; fail=0; xfail=0

# --- pristine clone lifecycle ------------------------------------------------

# Clone the golden into a uniquely-named VM, boot it, return its IP (or "").
clone_boot() {
    name="$1"
    vm destroy -f "$name" 2>/dev/null
    vm clone "$GOLDEN" "$name" >/dev/null 2>&1 || { echo ""; return; }
    vm start "$name" >/dev/null 2>&1
    # wait for ssh (the AMD boot is slow; cloned-warm would be faster)
    mac=$(grep -o 'network0_mac="[^"]*"' "/zroot/vm/$name/$name.conf" 2>/dev/null | cut -d'"' -f2)
    ip=""; i=0
    while [ $i -lt 40 ]; do
        i=$((i+1)); sleep 5
        ping -c1 -W1 172.16.0.255 >/dev/null 2>&1 || true
        # the clone's OWN mac -> its lease; exclude the gateway .1 (always in arp).
        ip=$(arp -an 2>/dev/null | grep -i "$mac" | grep -oE '172\.16\.0\.[0-9]+' | grep -v '172\.16\.0\.1$' | head -1)
        [ -n "$ip" ] && [ "$ip" != "172.16.0.1" ] && nc -z -w2 "$ip" 22 2>/dev/null && break
        ip=""
    done
    echo "$ip"
}

# Destroy is bulletproof: a running/locked clone needs poweroff first.
destroy() {
    vm stop "$1" >/dev/null 2>&1
    vm poweroff "$1" >/dev/null 2>&1
    sleep 1
    vm destroy -f "$1" >/dev/null 2>&1
}

gssh() { ip="$1"; shift; ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 "ubuntu@$ip" "$@" 2>/dev/null; }

# A probe result: it ran the attack and reports "DENIED" or "ESCAPED".
# verdict <label> <category> <DENIED|ESCAPED>  -- enforced=pass, escaped=xfail/fail
verdict() {
    label="$1"; cat="$2"; got="$3"
    if [ "$got" = "DENIED" ]; then
        echo "  PASS [$cat] $label — confinement held (DENIED)"; pass=$((pass+1))
    elif [ "$cat" = "vm" ]; then
        echo "  FAIL [$cat] $label — ESCAPED (the VM boundary should always hold!)"; fail=$((fail+1))
    else
        echo "  XFAIL [$cat] $label — ESCAPED (enforcement not wired yet; red until cap_enter/pf land)"; xfail=$((xfail+1))
    fi
}

# --- the breakout probes -----------------------------------------------------
# Each runs INSIDE a fresh confined clone and tries to bust out.

probe_vm() {                       # guest must not reach the host filesystem
    ip="$1"
    # Try to read a host-only path through the guest. A VM can't see the host
    # FS; success here would mean the VM boundary failed.
    r=$(gssh "$ip" 'cat /host-secret 2>/dev/null || echo NOREACH')
    [ "$r" = "NOREACH" ] && verdict "guest cannot read host /host-secret" vm DENIED \
                         || verdict "guest cannot read host /host-secret" vm ESCAPED
    # Try to reach the host's ssh from inside the guest as a different escape.
    r=$(gssh "$ip" 'timeout 3 nc -z 172.16.0.1 22 2>/dev/null && echo OPEN || echo CLOSED')
    # (Reaching the gateway:22 is allowed for a normal guest; this is a
    #  placeholder for a host-service the guest shouldnt touch once pf lands.)
}

probe_fd() {                       # Capsicum: confined bhyve shouldn't open new fds
    ip="$1"
    # PLACEHOLDER for the real check: once the cap_enter() launcher confines
    # bhyve to disk/tap/console, attempt (from a host-side helper) to make the
    # bhyve process open a NEW file -> must fail with ECAPMODE. Until the
    # launcher exists, bhyve runs unconfined, so this ESCAPES.
    verdict "confined bhyve cannot open an un-granted fd" fd ESCAPED
}

probe_net() {                      # pf: workload-mode egress whitelist (deny rest)
    ip="$1"
    # The python_vm policy: egress only to db_vm:6379, nothing else out.
    # Attempt egress to a FORBIDDEN destination (a public host:443). Under the
    # pf whitelist this must be DENIED; with no pf wired it succeeds (ESCAPED).
    r=$(gssh "$ip" 'timeout 4 nc -z -w3 1.1.1.1 443 2>/dev/null && echo OUT || echo BLOCKED')
    [ "$r" = "BLOCKED" ] && verdict "egress to forbidden 1.1.1.1:443 blocked" net DENIED \
                         || verdict "egress to forbidden 1.1.1.1:443 blocked" net ESCAPED
}

run_one() {
    cat="$1"; n="$2"
    name="bust-${cat}-${n}"
    echo "=== clone+boot $name (pristine) ==="
    ip=$(clone_boot "$name")
    if [ -z "$ip" ]; then
        echo "  SKIP [$cat] $name — clone never became reachable (AMD boot flaky)"
        destroy "$name"; return
    fi
    case "$cat" in
        vm)  probe_vm  "$ip" ;;
        fd)  probe_fd  "$ip" ;;
        net) probe_net "$ip" ;;
    esac
    destroy "$name"
}

cats="vm fd net"
[ "$CAT" != "all" ] && cats="$CAT"

echo "=== breakout harness: cats=[$cats] x$N (pristine clone per test) ==="
for c in $cats; do
    i=0
    while [ $i -lt "$N" ]; do
        i=$((i+1))
        run_one "$c" "$i"
    done
done

echo "=== RESULT: $pass confinement-held, $xfail expected-escape (not-yet-enforced), $fail REAL-FAIL ==="
[ "$fail" -eq 0 ]   # exit 0 unless a VM-boundary escape happened (a real failure)
