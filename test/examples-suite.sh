#!/bin/sh
# examples-suite.sh — the aeo example itest driver (aeo's analog of aeb's ab.sh).
#
# The examples are now PURE COMPOSITIONS: each declares its nodes + its own
# verification via check()/smoke()/suite() spec refs, and `aeo <phase> <file>` is
# the executor (exactly as `aeb <x>.build.ae` runs a build declaration). So this
# driver is THIN — it just picks examples and invokes the right aeo phase; the
# deploy + probe + teardown all happen inside aeo, driven by the declared specs.
#
#   sh test/examples-suite.sh check                 # data-model check, EVERY example (anywhere)
#   sh test/examples-suite.sh check <example.ae>    # one example
#   sh test/examples-suite.sh suite <example.ae>    # deploy + suite specs + teardown (needs a backend)
#   sh test/examples-suite.sh smoke <example.ae>    # deploy + smoke specs, leave standing
#
# `check` runs anywhere (no backend). `smoke`/`suite` need the substrate the example
# targets (podman for containers; a WSL/wslc Windows host for windows/wslc; etc.), so
# they take an explicit example rather than sweeping all — you run them where the
# backend lives (e.g. containers/confined on a podman host; windows/wslc on a Win box).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEO="${AEO:-/tmp/aeo}"
PHASE="${1:-check}"
ONE="${2:-}"

[ -x "$AEO" ] || {
    echo "MISSING: aeo binary at $AEO"
    echo "  build it: ae build bin/aeo.ae -o /tmp/aeo --lib lib"
    exit 1
}

# The load_balancer example deploys an aeo-lb CONTAINER; the driver bakes the
# image on demand (ensure_image) from AEO_HOME/bin/aeo-lb. Build that binary
# beside bin/aeo so a `up`-phase run of the LB example works out of the box.
if [ ! -x "$ROOT/bin/aeo-lb" ]; then
    ( cd "$ROOT" && ae build bin/aeo-lb.ae -o bin/aeo-lb --lib lib ) >/dev/null 2>&1 \
        || echo "  NOTE: could not build bin/aeo-lb (the load_balancer example's up phase needs it)"
fi

run_one() {
    ex="$1"
    echo "=== aeo $PHASE $(basename "$ex") ==="
    AEO_HOME="$ROOT" "$AEO" "$PHASE" "$ex"
    rc=$?
    if [ "$rc" = 0 ]; then echo "  PASS ($PHASE)"; else echo "  FAIL ($PHASE) rc=$rc"; fi
    return $rc
}

fails=0
if [ -n "$ONE" ]; then
    run_one "$ONE" || fails=1
else
    # no example named: sweep every example through the phase (only sensible for
    # `check`, which needs no backend — smoke/suite would try to deploy 12 stacks).
    if [ "$PHASE" != "check" ]; then
        echo "sweep is only supported for 'check' (smoke/suite need a live backend)."
        echo "run one example: sh test/examples-suite.sh $PHASE examples/<one>.ae"
        exit 2
    fi
    for ex in "$ROOT"/examples/silly_addition_*.ae; do
        run_one "$ex" || fails=1
    done
fi

[ "$fails" = 0 ] && echo "=== all $PHASE checks PASSED ===" || echo "=== some $PHASE checks FAILED ==="
exit $fails
