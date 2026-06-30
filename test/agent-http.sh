#!/bin/sh
# agent-http.sh — prove the aeo-agent over the HTTP transport on localhost: the
# module swap (file -> http) works, and the bank-courier auth is enforced on a
# REAL socket. No substrate (AEO_BOOT_NOOP).
#
#   sh test/agent-http.sh
#
# Asserts:
#   1. GET  /health           -> 200 "ok"            (open residence probe)
#   2. POST /dispatch (good token) "boot <tok> n1"   -> 200, body "report <tok> n1 up"
#   3. POST /dispatch (WRONG token)                  -> 401                 (fail-closed)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/aeo-agent"
PORT="${AEO_PORT:-9457}"
TOK="courier-$$"
BASE="http://127.0.0.1:$PORT"

[ -x "$AGENT" ] || ( cd "$ROOT" && ae build bin/aeo-agent.ae ) || { echo "BUILD FAILED"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

AEO_TRANSPORT=http AEO_PORT="$PORT" AEO_NODE="n1" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 "$AGENT" > /tmp/agent-http.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT

# Wait for the listener.
i=0
while ! curl -fsS "$BASE/health" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: server never came up"; cat /tmp/agent-http.log; exit 1; }
    sleep 0.1
done

fail=0

# 1. health
h="$(curl -fsS "$BASE/health" 2>/dev/null)"
[ "$h" = "ok" ] && echo "PASS /health -> ok" || { echo "FAIL /health -> '$h'"; fail=1; }

# 2. authed dispatch — good token
body="boot $TOK n1"
rep="$(curl -fsS -X POST --data "$body" "$BASE/dispatch" 2>/dev/null)"
want="report $TOK n1 up"
[ "$rep" = "$want" ] && echo "PASS /dispatch (good token) -> '$rep'" || { echo "FAIL /dispatch -> '$rep' (want '$want')"; fail=1; }

# 3. wrong token -> 401 (curl -f makes a 401 a non-zero exit + empty body)
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST --data "boot WRONG-TOKEN n1" "$BASE/dispatch" 2>/dev/null)"
[ "$code" = "401" ] && echo "PASS /dispatch (wrong token) -> 401 (fail-closed)" || { echo "FAIL /dispatch wrong token -> HTTP $code (want 401)"; fail=1; }

echo "--- agent log ---"; cat /tmp/agent-http.log
if [ "$fail" -eq 0 ]; then
    echo "PASS: aeo-agent http transport — module swap + auth on a real socket"
    exit 0
fi
echo "FAIL: http transport proof"
exit 1
