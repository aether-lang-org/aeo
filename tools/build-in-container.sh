#!/bin/sh
# tools/build-in-container.sh — build aeo + aeo-agent (and run demos) inside a
# container on an IMMUTABLE host (Bazzite / Silverblue / Fedora-atomic) that
# won't let you install gcc + Aether's aetherc. Same tech that builds aeb in a
# container (../aeb/tools/container); aeo only needs `ae` (not aeb), so the
# upstream `aether-builder` base — or any aeb-toolchain image, which layers on it
# — suffices. Verified on Bazzite 2026-06-26 (aeb-toolchain:fresh, ae 0.257).
#
#   sh tools/build-in-container.sh                 # build aeo + aeo-agent -> ./out
#   AEO_CHECK=examples/silly_addition_kvm.ae \
#       sh tools/build-in-container.sh             # + ae-run that demo's check
#
# Env:
#   AEO_TC_IMAGE   toolchain image (default localhost/aeb-toolchain:fresh)
#   AEOCHA_DIR     path to an aeocha checkout (for AEO_CHECK runs; default ../aeocha)
#   AEO_CHECK      a demo .ae to `ae run` (check mode) after building
#
# Bazzite/SELinux traps (documented in ../aether/ctr_notes.md):
#   - bind mounts need :Z  (relabel for the container)
#   - the work dir must NOT be $HOME (relabeling $HOME is refused)
#   - do NOT pass --userns=keep-id (crashes this crun; output is user-owned anyway)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="${AEO_TC_IMAGE:-localhost/aeb-toolchain:fresh}"
OUT="$ROOT/out"
mkdir -p "$OUT"

run_ae() {
    # run a shell line inside the toolchain container with aeo bind-mounted at
    # /work and out at /out. $1 = the `cd /work && ...` command.
    podman run --rm \
        -v "$ROOT:/work:Z" \
        -v "$OUT:/out:Z" \
        ${AEOCHA_MOUNT:-} \
        "$TC" \
        sh -c "$1"
}

echo "== building aeo (front-door) =="
run_ae "cd /work && ae build bin/aeo.ae -o /out/aeo --lib lib"

echo "== building aeo-agent =="
run_ae "cd /work && ae build bin/aeo-agent.ae -o /out/aeo-agent --lib lib"

ls -lh "$OUT/aeo" "$OUT/aeo-agent"
echo "== aeo + aeo-agent built -> $OUT (run on the host directly) =="

# Optional: ae-run a demo's check mode in the container (self-contained — no
# host `ae`, no front-door). Needs aeocha on the include path.
if [ -n "${AEO_CHECK:-}" ]; then
    AEOCHA="${AEOCHA_DIR:-$ROOT/../aeocha}"
    if [ ! -f "$AEOCHA/aeocha.ae" ]; then
        echo "AEO_CHECK set but aeocha not found at $AEOCHA (set AEOCHA_DIR)"; exit 1
    fi
    echo "== ae run (check) $AEO_CHECK =="
    AEOCHA_MOUNT="-v $AEOCHA:/aeocha:Z" \
        run_ae "cd /work && AEO_MODE=check ae run $AEO_CHECK --lib lib --lib /aeocha"
fi

# NOTE on `aeo up` (DEPLOY) on an immutable host: the aeo front-door BUILDS the
# composition at runtime (it shells `ae build`), so it needs `ae` on PATH when it
# runs. On Bazzite that means running `aeo` ITSELF inside this container (where
# `ae` lives), or installing `ae` on the host. `ae run <demo>` check mode above
# sidesteps this (it's self-contained); full deploy is the next step.
