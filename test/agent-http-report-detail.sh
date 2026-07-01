#!/bin/sh
# agent-http-report-detail.sh — prove the middle agent relays the child's REAL
# report state (up vs failed) up the tree via the response BODY, not just a
# 200/non-200 status bit. This is what the UAF fix (aether v0.341.0, fee8118 —
# response_body is an owned string, safe after an in-handler dial) unblocked:
# _delegate_child_http reads send_command's body again instead of status-only.
#
# Two children on distinct ports: one boots OK (AEO_BOOT_NOOP), one is forced to
# FAIL (AEO_BOOT_FAIL). The parent delegates each; we assert the parent relays
# 'up' for the first and 'failed' for the second — a distinction status-only
# (200 vs non-200) could carry, but richer detail (WHY it failed) needs the body.
# Here we prove the up/failed state itself round-trips through the body path.
#
#   sh test/agent-http-report-detail.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/aeo-agent"
TOK="courier-$$"
P_PORT="${AEO_BASE_PORT:-9471}"          # parent
OK_PORT=$((P_PORT+1))                     # child that boots ok
BAD_PORT=$((P_PORT+2))                    # child forced to fail
PARENT="http://127.0.0.1:$P_PORT"

[ -x "$AGENT" ] || ( cd "$ROOT" && ae build bin/aeo-agent.ae ) || { echo "BUILD FAILED"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

# okchild: boots fine.
AEO_TRANSPORT=http AEO_PORT="$OK_PORT" AEO_NODE="okchild" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    "$AGENT" > /tmp/rd-ok.log 2>&1 & OK_PID=$!
# badchild: forced boot failure.
AEO_TRANSPORT=http AEO_PORT="$BAD_PORT" AEO_NODE="badchild" AEO_TOKEN="$TOK" AEO_BOOT_FAIL=1 \
    "$AGENT" > /tmp/rd-bad.log 2>&1 & BAD_PID=$!
# parent: knows both children's ports (courier stamped them).
AEO_TRANSPORT=http AEO_PORT="$P_PORT" AEO_NODE="parent" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    AEO_PORT_okchild="$OK_PORT" AEO_PORT_badchild="$BAD_PORT" \
    "$AGENT" > /tmp/rd-parent.log 2>&1 & P_PID=$!

trap 'kill "$OK_PID" "$BAD_PID" "$P_PID" 2>/dev/null' EXIT

for hp in "$P_PORT" "$OK_PORT" "$BAD_PORT"; do
    i=0
    while ! curl -fsS "http://127.0.0.1:$hp/health" >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: agent on $hp never came up"; cat /tmp/rd-*.log; exit 1; }
        sleep 0.1
    done
done

fail=0

# delegate the OK child -> parent relays its 'up' (from the body).
rok="$(curl -fsS -X POST --data "delegate $TOK okchild" "$PARENT/dispatch" 2>/dev/null)"
[ "$rok" = "report $TOK okchild up" ] \
    && echo "PASS ok-child relayed -> '$rok'" \
    || { echo "FAIL ok-child -> '$rok' (want 'report $TOK okchild up')"; fail=1; }

# delegate the FAILING child -> parent relays 'failed' (the DETAIL, via body).
rbad="$(curl -fsS -X POST --data "delegate $TOK badchild" "$PARENT/dispatch" 2>/dev/null)"
[ "$rbad" = "report $TOK badchild failed" ] \
    && echo "PASS bad-child relayed -> '$rbad' (real state via body, not a status bit)" \
    || { echo "FAIL bad-child -> '$rbad' (want 'report $TOK badchild failed')"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "PASS: middle agent relays real child state (up AND failed) via the response body"
    exit 0
fi
echo "--- parent.log ---"; cat /tmp/rd-parent.log
echo "FAIL: report-detail propagation"
exit 1
