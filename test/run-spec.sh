#!/bin/sh
# run-spec.sh — run the Aeocha BDD spec(s) for aeo.
#
# Aeocha (the BDD test framework) is a sibling checkout; we add it and aeo's
# own lib/ to the module path. The spec's data-model cases run anywhere; the
# live-deployment cases run only when AEO_VERIFY=1 (against a deployed system
# — see test/spec_nested_system.ae).
#
#   sh test/run-spec.sh                    # data-model spec (runs anywhere)
#   AEO_VERIFY=1 sh test/run-spec.sh       # + live HTTP checks vs a deployment
#   AEOCHA=/path/to/aeocha sh test/run-spec.sh   # override aeocha location
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEOCHA="${AEOCHA:-$(cd "$ROOT/../aeocha" 2>/dev/null && pwd || true)}"

if [ -z "$AEOCHA" ] || [ ! -f "$AEOCHA/aeocha.ae" ]; then
    echo "aeocha not found. Clone it next to aeo, or set AEOCHA=/path/to/aeocha"
    echo "  (expected $ROOT/../aeocha/aeocha.ae)"
    exit 1
fi

ae run "$ROOT/test/spec_nested_system.ae" --lib "$ROOT/lib" --lib "$AEOCHA"
