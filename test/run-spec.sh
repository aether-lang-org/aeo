#!/bin/sh
# run-spec.sh — run aeo's Aeocha BDD spec(s).
#
# Aeocha (the BDD test framework) is a sibling checkout; we add it and aeo's
# own lib/ to the module path. Data-model cases run anywhere; live-deployment
# cases run only when AEO_VERIFY=1 (against a deployed system).
#
#   sh test/run-spec.sh                         # run every test/spec_*.ae
#   sh test/run-spec.sh test/spec_running_nodes.ae   # run one spec
#   AEO_VERIFY=1 sh test/run-spec.sh            # + live checks
#   AEOCHA=/path/to/aeocha sh test/run-spec.sh  # override aeocha location
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEOCHA="${AEOCHA:-$(cd "$ROOT/../aeocha" 2>/dev/null && pwd || true)}"

if [ -z "$AEOCHA" ] || [ ! -f "$AEOCHA/aeocha.ae" ]; then
    echo "aeocha not found. Clone it next to aeo, or set AEOCHA=/path/to/aeocha"
    echo "  (expected $ROOT/../aeocha/aeocha.ae)"
    exit 1
fi

run_one() {
    echo "### $1"
    # build-then-run, not `ae run`: `ae run` caches by content and can serve a
    # stale compiled dependency (e.g. an edited lib/compose) — build to a fresh
    # binary each time so edits always take.
    bin="/tmp/aeo-spec-$(basename "$1" .ae)"
    ae build "$1" -o "$bin" --lib "$ROOT/lib" --lib "$AEOCHA" || return 1
    "$bin"
}

if [ "$#" -gt 0 ]; then
    for spec in "$@"; do run_one "$spec"; done
else
    for spec in "$ROOT"/test/spec_*.ae; do run_one "$spec"; done
fi
