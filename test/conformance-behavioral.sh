#!/bin/sh
# conformance-behavioral.sh — the BEHAVIORAL driver-conformance lifecycle (item 4).
#
# The contract-shape half is test/spec_driver_conformance.ae (pure). This half runs
# the create -> probe-healthy -> confinement-present -> stop -> VERIFY-GONE lifecycle
# LIVE, driving the real `aeo` front-door (not raw podman/jail), so it proves the aeo
# contract end to end. Parameterized by substrate; host-gated by the caller.
#
# Usage:
#   AEO_HOME=/path/to/aeo sh test/conformance-behavioral.sh <aeo-binary> <substrate>
#     substrate = container | jail   (v1; more as drivers gain the seam)
#
# Exits 0 iff every stage passes. Each stage prints PASS/FAIL. A running host is
# required (podman for container, a FreeBSD jail host for jail).

set -u
AEO="${1:?usage: conformance-behavioral.sh <aeo-binary> <substrate>}"
SUB="${2:?substrate: container|jail}"
WORK="$(mktemp -d)"
FAILED=0
say() { printf '%s\n' "$*"; }
ok()  { say "  PASS: $*"; }
bad() { say "  FAIL: $*"; FAILED=1; }

# --- build the one-node confined composition for this substrate ---------------
case "$SUB" in
  container)
    NODE="cnode"; SYS="conf_container"
    cat > "$WORK/c.ae" <<AE
import compose (system, container, image, command, limit, limit_mem, limit_maxproc)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("$SYS") {
        c = container("$NODE") { image("docker.io/library/alpine:latest") command("sleep 600") }
        limit(c) { limit_mem("128M") limit_maxproc(16) }
    }
}
AE
    CONFINE_CHECK() { podman inspect "$NODE" --format '{{.HostConfig.Memory}}' 2>/dev/null; }
    CONFINE_WANT="134217728"
    LIVE_CHECK() { podman ps --filter "name=^${NODE}\$" --filter status=running --format '{{.Names}}' 2>/dev/null; }
    ;;
  jail)
    # NOTE: the jail arm needs a REAL jail rootfs on the dataset (a bootable
    # base.txz-populated tree), not just an empty zfs dataset — otherwise `jail -c`
    # starts a jail with no /bin/sh. Point AEO_CONF_JAIL_ROOT at a staged jail root,
    # or pre-create zroot/conf/jnode with a base install. This is why the jail arm is
    # gated on a prepared FreeBSD host, not run in CI.
    NODE="jnode"; SYS="conf_jail"
    ROOTDS="${AEO_CONF_JAIL_DATASET:-zroot/conf/$NODE}"
    cat > "$WORK/c.ae" <<AE
import compose (system, jail, dataset, limit, limit_mem)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("$SYS") {
        j = jail("$NODE") { dataset("$ROOTDS") }
        limit(j) { limit_mem("256M") }
    }
}
AE
    # the rctl cap aeo applied on `up`: `rctl jail:<node>` lists it
    # (jail:jnode:memoryuse:deny=268435456). Needs the same sudo grant aeo uses.
    CONFINE_CHECK() { sudo -n rctl "jail:$NODE" 2>/dev/null | head -1; }
    CONFINE_WANT="memoryuse"
    LIVE_CHECK() { sudo -n jls -j "$NODE" name 2>/dev/null; }
    ;;
  *) say "unknown substrate '$SUB'"; exit 2 ;;
esac

say "=== behavioral conformance: substrate=$SUB node=$NODE ==="

# --- stage 1: CREATE (aeo up) -------------------------------------------------
"$AEO" up "$WORK/c.ae" >/dev/null 2>&1
sleep 2

# --- stage 2: PROBE-HEALTHY (the node is live) --------------------------------
if [ -n "$(LIVE_CHECK)" ]; then ok "created + probe reports running"; else bad "node not running after up"; fi

# --- stage 3: CONFINEMENT PRESENT (the declared cap is on the live resource) --
GOT="$(CONFINE_CHECK)"
case "$GOT" in
  *"$CONFINE_WANT"*) ok "confinement flag present ($CONFINE_WANT)";;
  *) bad "confinement flag absent (wanted $CONFINE_WANT, got '$GOT')";;
esac

# --- stage 4: STOP (aeo down) -------------------------------------------------
"$AEO" down "$WORK/c.ae" >/dev/null 2>&1
sleep 2

# --- stage 5: VERIFY-GONE (the aeo teardown guarantee) ------------------------
if [ -z "$(LIVE_CHECK)" ]; then ok "verify-gone: node is provably absent after down"; else bad "node still present after down"; fi

rm -rf "$WORK"
if [ "$FAILED" -eq 0 ]; then say "=== CONFORMANCE PASS ($SUB) ==="; exit 0; else say "=== CONFORMANCE FAIL ($SUB) ==="; exit 1; fi
