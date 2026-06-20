#!/bin/sh
# Provision a minimal bootable jail root for test/real_jail.ae on FreeBSD.
# Creates a ZFS dataset and populates it with the host's /rescue (a
# self-contained set of statically-linked tools — sh, test, true, …) plus
# the empty mountpoint dirs a jail expects. Root required.
#
#   sudo sh test/setup-jail-root.sh
#   sudo /tmp/real_jail            # then run the test
#   sudo sh test/setup-jail-root.sh --teardown   # cleanup
#
# This stands in for an operator's provision(...) step — aeo does not ship
# a userland; it orchestrates one the operator populates.
set -eu

DATASET="zroot/jails/aeo-rj"
ROOT="/zroot/jails/aeo-rj"

if [ "${1:-}" = "--teardown" ]; then
    jail -r aeo-rj 2>/dev/null || true
    zfs destroy -r "$DATASET" 2>/dev/null || true
    echo "torn down $DATASET"
    exit 0
fi

# Create the dataset if absent (idempotent).
if ! zfs list "$DATASET" >/dev/null 2>&1; then
    zfs create -p "$DATASET"
fi

# Populate: /rescue (static tools) + the dirs jail/jexec expect.
mkdir -p "$ROOT/rescue" "$ROOT/dev" "$ROOT/tmp" "$ROOT/bin" "$ROOT/etc"
cp -a /rescue/. "$ROOT/rescue/"
# Symlink /bin/sh -> /rescue/sh so default jail commands resolve.
ln -sf /rescue/sh "$ROOT/bin/sh" 2>/dev/null || true

echo "jail root ready at $ROOT (rescue tools installed)"
echo "now: sudo /tmp/real_jail"
