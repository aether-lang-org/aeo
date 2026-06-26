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
    # The Capsicum/containment specs are FreeBSD-only. Two flavours:
    #  - C-helper specs (bhyve_model, breakout) use test/capfd.c, whose FreeBSD
    #    errnos (ECAPMODE/ENOTCAPABLE) won't even C-compile off FreeBSD.
    #  - SELF-REPORT specs (jail/bhyvevm) drive a python3 harness that spawns a
    #    self-confining probe inside a jail/VM (test/capharness.py + capprobe.py)
    #    — no C helper; they need python3 + sudo jail/jexec + the harness staged
    #    to /tmp. (jail self-report is RUNNABLE on this box, verified 2026-06-26.)
    # Off FreeBSD, skip all of them.
    extra=""
    case "$1" in
        *spec_capsicum_*|*spec_containment_*)
            if [ "$OS" != "FreeBSD" ]; then
                echo "  (skipped — FreeBSD-only: Capsicum kernel + BSD errnos)"
                return
            fi
            ;;
    esac
    case "$1" in
        *spec_capsicum_bhyve_model*|*spec_capsicum_breakout*)
            extra="--extra $ROOT/test/capfd.c" ;;
        *spec_capsicum_jail_selfreport*|*spec_capsicum_bhyvevm_selfreport*)
            # stage the python harness the spec shells to /tmp.
            cp "$ROOT/test/capharness.py" "$ROOT/test/capprobe.py" /tmp/ 2>/dev/null || true
            cp "$ROOT/test/capharness_freebsd.py" "$ROOT/test/capprobe_freebsd.c" /tmp/ 2>/dev/null || true
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
