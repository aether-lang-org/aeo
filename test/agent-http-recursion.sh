#!/bin/sh
# agent-http-recursion.sh — prove aeo-agent RECURSION over the HTTP transport on
# localhost, no substrate. Two real agents nest one level, each an http server on
# its own port (the addressing convention: parent assigns sequential ports). The
# `outer` agent is told to `delegate inner`; outer acts as http CLIENT to inner's
# listener (http://127.0.0.1:<inner-port>/dispatch), relays inner's report up.
#
# This is the file-transport recursion proof (test/agent-recursion.sh) redone
# over a real socket with real auth — the full agent conduit on localhost, TLS
# aside. Depth-agnostic: outer runs the SAME client code inner would for ITS
# children, so two levels prove N.
#
#   sh test/agent-http-recursion.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/aeo-agent"
TOK="courier-$$"
OUTER_PORT="${AEO_BASE_PORT:-9461}"
INNER_PORT=$((OUTER_PORT+1))        # sequential: parent assigns base+depth
OUTER="http://127.0.0.1:$OUTER_PORT"

[ -x "$AGENT" ] || ( cd "$ROOT" && ae build bin/aeo-agent.ae ) || { echo "BUILD FAILED"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

# inner: an http agent on its own port.
AEO_TRANSPORT=http AEO_PORT="$INNER_PORT" AEO_NODE="inner" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    "$AGENT" > /tmp/http-rec-inner.log 2>&1 &
INNER_PID=$!

# outer: an http agent that KNOWS inner's assigned port (the courier stamped it —
# here the harness plays courier via AEO_PORT_inner). outer will http-client to it.
AEO_TRANSPORT=http AEO_PORT="$OUTER_PORT" AEO_NODE="outer" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 \
    AEO_PORT_inner="$INNER_PORT" \
    "$AGENT" > /tmp/http-rec-outer.log 2>&1 &
OUTER_PID=$!

trap 'kill "$OUTER_PID" "$INNER_PID" 2>/dev/null' EXIT

# Wait for both listeners.
for hp in "$OUTER_PORT" "$INNER_PORT"; do
    i=0
    while ! curl -fsS "http://127.0.0.1:$hp/health" >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: agent on $hp never came up"; cat /tmp/http-rec-*.log; exit 1; }
        sleep 0.1
    done
done

fail=0

# 1. outer boots ITSELF (baseline single-level over http).
r1="$(curl -fsS -X POST --data "boot $TOK outer" "$OUTER/dispatch" 2>/dev/null)"
[ "$r1" = "report $TOK outer up" ] && echo "PASS outer self-boot -> '$r1'" || { echo "FAIL outer self-boot -> '$r1'"; fail=1; }

# 2. THE RECURSION: outer delegates inner -> outer http-clients inner -> relays up.
r2="$(curl -fsS -X POST --data "delegate $TOK inner" "$OUTER/dispatch" 2>/dev/null)"
[ "$r2" = "report $TOK inner up" ] && echo "PASS recursion: outer delegated inner over http -> '$r2'" || { echo "FAIL recursion -> '$r2' (want 'report $TOK inner up')"; fail=1; }

# 3. auth still fail-closed at the top.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST --data "delegate WRONG inner" "$OUTER/dispatch" 2>/dev/null)"
[ "$code" = "401" ] && echo "PASS wrong-token delegate -> 401" || { echo "FAIL wrong-token -> HTTP $code (want 401)"; fail=1; }

echo "--- outer.log ---"; cat /tmp/http-rec-outer.log
echo "--- inner.log ---"; cat /tmp/http-rec-inner.log
if [ "$fail" -eq 0 ]; then
    echo "PASS: http recursion converged (inner report relayed up through outer over a real socket)"
    exit 0
fi
echo "FAIL: http recursion"
exit 1
