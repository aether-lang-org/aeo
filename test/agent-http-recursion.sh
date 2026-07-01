#!/bin/sh
# agent-http-recursion.sh — prove aeo-agent RECURSION over the HTTP transport on
# localhost, no substrate. THREE real agents, two levels, mirroring the real
# deployment's names:
#
#   grandparent  (= aeo on the host)           http client only
#     └─ parent  (= the VM-agent, in a VM)      SERVER to grandparent, CLIENT to child
#          └─ child (= the container-agent)     server only (leaf)
#
# The interesting one is PARENT: a middle agent that must serve its grandparent
# AND dial its child in the same handler — "serve-and-dial" (unblocked by
# server_start_background + the aether v0.341.0 response-body fix). grandparent
# delegates parent; parent, inside that handler, delegates child; the child's
# report relays all the way up. Two levels prove N.
#
# Each agent is an http server on its own port (addressing convention: the parent
# assigns sequential ports, here the harness plays courier via AEO_PORT_<child>).
# Boots are NOOP (AEO_BOOT_NOOP) — proves the tree converges, not that a container
# ran (the substrate is proven separately on a box that has one).
#
#   sh test/agent-http-recursion.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/aeo-agent"
TOK="courier-$$"
GP_PORT="${AEO_BASE_PORT:-9461}"     # grandparent
P_PORT=$((GP_PORT+1))                 # parent   (base+1)
C_PORT=$((GP_PORT+2))                 # child    (base+2)
GP="http://127.0.0.1:$GP_PORT"

[ -x "$AGENT" ] || ( cd "$ROOT" && ae build bin/aeo-agent.ae ) || { echo "BUILD FAILED"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

# child: leaf http agent on its own port.
AEO_TRANSPORT=http AEO_PORT="$C_PORT" AEO_NODE="child" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    "$AGENT" > /tmp/http-rec-child.log 2>&1 & C_PID=$!

# parent: the middle agent. Knows child's assigned port (courier stamped it), so
# it can dial child from inside its own /dispatch handler (serve-and-dial).
AEO_TRANSPORT=http AEO_PORT="$P_PORT" AEO_NODE="parent" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    AEO_PORT_child="$C_PORT" \
    "$AGENT" > /tmp/http-rec-parent.log 2>&1 & P_PID=$!

# grandparent: knows parent's assigned port.
AEO_TRANSPORT=http AEO_PORT="$GP_PORT" AEO_NODE="grandparent" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    AEO_PORT_parent="$P_PORT" \
    "$AGENT" > /tmp/http-rec-gp.log 2>&1 & GP_PID=$!

trap 'kill "$GP_PID" "$P_PID" "$C_PID" 2>/dev/null' EXIT

# Wait for all three listeners.
for hp in "$GP_PORT" "$P_PORT" "$C_PORT"; do
    i=0
    while ! curl -fsS "http://127.0.0.1:$hp/health" >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: agent on $hp never came up"; cat /tmp/http-rec-*.log; exit 1; }
        sleep 0.1
    done
done

fail=0

# 1. grandparent boots ITSELF (baseline single-level over http).
r1="$(curl -fsS -X POST --data "boot $TOK grandparent" "$GP/dispatch" 2>/dev/null)"
[ "$r1" = "report $TOK grandparent up" ] && echo "PASS grandparent self-boot -> '$r1'" || { echo "FAIL grandparent self-boot -> '$r1'"; fail=1; }

# 2. ONE level: grandparent delegates parent -> parent boots itself, relays up.
r2="$(curl -fsS -X POST --data "delegate $TOK parent" "$GP/dispatch" 2>/dev/null)"
[ "$r2" = "report $TOK parent up" ] && echo "PASS grandparent->parent -> '$r2'" || { echo "FAIL grandparent->parent -> '$r2'"; fail=1; }

# 3. TWO levels (the real recursion): grandparent delegates parent, but this time
#    we drive parent directly to delegate child, proving the MIDDLE agent (parent)
#    serves-and-dials — it answers grandparent's transport AND dials child.
r3="$(curl -fsS -X POST --data "delegate $TOK child" "http://127.0.0.1:$P_PORT/dispatch" 2>/dev/null)"
[ "$r3" = "report $TOK child up" ] && echo "PASS parent->child (middle serve-and-dial) -> '$r3'" || { echo "FAIL parent->child -> '$r3' (want 'report $TOK child up')"; fail=1; }

# 4. auth still fail-closed at the top.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST --data "delegate WRONG child" "http://127.0.0.1:$P_PORT/dispatch" 2>/dev/null)"
[ "$code" = "401" ] && echo "PASS wrong-token delegate -> 401" || { echo "FAIL wrong-token -> HTTP $code (want 401)"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "PASS: http recursion converged across two levels (grandparent -> parent -> child)"
    exit 0
fi
echo "--- gp.log ---"; cat /tmp/http-rec-gp.log
echo "--- parent.log ---"; cat /tmp/http-rec-parent.log
echo "--- child.log ---"; cat /tmp/http-rec-child.log
echo "FAIL: http recursion"
exit 1
