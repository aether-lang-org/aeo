#!/bin/sh
# agent-recursion.sh — prove aeo-agent RECURSION with the file transport, no
# substrate. Two real agent processes nest one level: an `outer` agent (stands
# for an agent inside a VM) is told to `delegate` an `inner` agent (stands for a
# container nested in that VM). outer hands a boot DOWN to inner's inbox, waits
# for inner's report, and relays it UP. The root parent here is this script,
# writing into outer's inbox and reading outer's outbox.
#
# This is the depth-agnostic claim made concrete: outer runs the SAME code inner
# would for ITS children, so two levels proves N. Boots are NOOP (AEO_BOOT_NOOP)
# so the proof is "the orchestration tree converges", not "podman ran" — the
# substrate is tested elsewhere.
#
#   sh test/agent-recursion.sh
#
# Exit 0 = the report chain came back up (inner -> outer -> root). Non-zero =
# the recursion did not converge.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/aeo-agent"
RV="${AEO_RENDEZVOUS:-/tmp/aeo-recursion-test}"
TOK="courier-$$"            # a single shared token for this run (warn-level v0)

# Clean slate.
rm -rf "$RV"
mkdir -p "$RV"

# Build the agent if it isn't there.
if [ ! -x "$AGENT" ]; then
    echo "building aeo-agent..."
    ( cd "$ROOT" && ae build bin/aeo-agent.ae ) || { echo "BUILD FAILED"; exit 2; }
fi

echo "rendezvous: $RV"
echo "token:      $TOK"

# Launch the two agents. Each polls its OWN inbox; AEO_BOOT_NOOP makes boots a
# no-op so no container substrate is needed.
AEO_RENDEZVOUS="$RV" AEO_NODE="outer" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 "$AGENT" > "$RV/outer.log" 2>&1 &
OUTER_PID=$!
AEO_RENDEZVOUS="$RV" AEO_NODE="inner" AEO_TOKEN="$TOK" AEO_BOOT_NOOP=1 "$AGENT" > "$RV/inner.log" 2>&1 &
INNER_PID=$!
echo "launched: outer=$OUTER_PID inner=$INNER_PID"

cleanup() { kill "$OUTER_PID" "$INNER_PID" 2>/dev/null; }
trap cleanup EXIT

# Give the agents a moment to ensure_dirs + announce.
i=0
while [ ! -d "$RV/inbox/outer" ] || [ ! -d "$RV/inbox/inner" ]; do
    i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: agents never created inboxes"; exit 1; }
    sleep 0.1
done

# ROOT PARENT (this script) hands DOWN to the outer agent:
#   1. boot outer        — outer brings up its OWN node
#   2. delegate inner    — outer becomes inner's parent, recurses one level
seq=1
emit() { printf '%s %s %s\n' "$1" "$TOK" "$2" > "$RV/inbox/outer/$(printf '%06d' "$seq").cmd"; seq=$((seq+1)); }
emit boot     outer
emit delegate inner

# Read outer's outbox for the relayed reports. We expect (in some order):
#   report <tok> outer up      (outer booted itself)
#   report <tok> inner up      (outer relayed inner's report UP — the recursion)
got_outer=0
got_inner=0
i=0
while [ "$got_outer" -eq 0 ] || [ "$got_inner" -eq 0 ]; do
    i=$((i+1)); [ "$i" -gt 100 ] && break
    for f in "$RV"/outbox/outer/*.cmd; do
        [ -e "$f" ] || continue
        line="$(cat "$f")"
        case "$line" in
            "report $TOK outer up")    got_outer=1 ;;
            "report $TOK inner up")    got_inner=1 ;;
        esac
    done
    sleep 0.1
done

echo "got_outer=$got_outer got_inner=$got_inner"

# Phase 2 — AUTH: a command bearing a WRONG token must be REFUSED (fail-closed).
# Send a boot for a fresh node `intruder` with a bogus token; assert NO report
# for it ever appears in outer's outbox (the agent drops it, keeps serving).
printf 'boot %s %s\n' "WRONG-TOKEN" "intruder" > "$RV/inbox/outer/$(printf '%06d' "$seq").cmd"; seq=$((seq+1))
got_intruder=0
i=0
while [ "$i" -lt 30 ]; do            # ~3s — long enough for a report to show if it would
    i=$((i+1))
    for f in "$RV"/outbox/outer/*.cmd; do
        [ -e "$f" ] || continue
        case "$(cat "$f")" in
            *"intruder"*) got_intruder=1 ;;
        esac
    done
    sleep 0.1
done

echo "--- outer.log ---"; cat "$RV/outer.log"
echo "--- inner.log ---"; cat "$RV/inner.log"
echo "---"
echo "got_outer=$got_outer got_inner=$got_inner got_intruder=$got_intruder (want 1 1 0)"

if [ "$got_outer" -eq 1 ] && [ "$got_inner" -eq 1 ] && [ "$got_intruder" -eq 0 ]; then
    echo "PASS: recursion converged AND wrong-token boot was refused (fail-closed)"
    exit 0
fi
echo "FAIL: convergence=$got_outer/$got_inner intruder-refused=$([ $got_intruder -eq 0 ] && echo yes || echo NO)"
exit 1
