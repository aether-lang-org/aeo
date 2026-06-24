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
#
# One spec failing to build or run does NOT abort the rest — each is reported
# and the script exits non-zero at the end if any failed. (Some specs are
# FreeBSD-only — the capsicum/containment ones need a Capsicum kernel — and
# will fail to run off-BSD; that must not mask the rest of the suite.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEOCHA="${AEOCHA:-$(cd "$ROOT/../aeocha" 2>/dev/null && pwd || true)}"

if [ -z "$AEOCHA" ] || [ ! -f "$AEOCHA/aeocha.ae" ]; then
    echo "aeocha not found. Clone it next to aeo, or set AEOCHA=/path/to/aeocha"
    echo "  (expected $ROOT/../aeocha/aeocha.ae)"
    exit 1
fi

failures=""
OS="$(uname -s)"

run_one() {
    echo "### $1"
    # The Capsicum/containment specs are FreeBSD-only by construction: their C
    # helper (test/capfd.c) uses FreeBSD-only errnos (ECAPMODE/ENOTCAPABLE) and
    # they enforce against a real Capsicum kernel. They won't even C-compile off
    # FreeBSD, so SKIP them there rather than report a spurious failure.
    extra=""
    case "$1" in
        *spec_capsicum_*|*spec_containment_*)
            if [ "$OS" != "FreeBSD" ]; then
                echo "  (skipped — FreeBSD-only: Capsicum kernel + BSD errnos)"
                return
            fi
            extra="--extra $ROOT/test/capfd.c"
            ;;
    esac
    # build-then-run, not `ae run`: `ae run` caches by content and can serve a
    # stale compiled dependency (e.g. an edited lib/compose) — build to a fresh
    # binary each time so edits always take.
    bin="/tmp/aeo-spec-$(basename "$1" .ae)"
    if ! ae build "$1" -o "$bin" --lib "$ROOT/lib" --lib "$AEOCHA" $extra; then
        echo "  (build failed)"
        failures="$failures $1"
        return
    fi
    if ! "$bin"; then
        failures="$failures $1"
    fi
}

if [ "$#" -gt 0 ]; then
    for spec in "$@"; do run_one "$spec"; done
else
    for spec in "$ROOT"/test/spec_*.ae; do run_one "$spec"; done
fi

if [ -n "$failures" ]; then
    echo
    echo "FAILED specs:$failures"
    exit 1
fi
