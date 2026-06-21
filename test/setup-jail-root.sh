#!/bin/sh
# Provision a minimal bootable jail root on FreeBSD. Creates a ZFS dataset
# and populates it with the host's /rescue (a self-contained set of
# statically-linked tools — sh, test, true, …) plus the empty mountpoint
# dirs a jail expects. Root required.
#
#   sudo sh test/setup-jail-root.sh [name]       # default name: db
#   sudo sh test/setup-jail-root.sh db           # the nested_compose DSL's jail
#   sudo sh test/setup-jail-root.sh --teardown [name]
#
# This stands in for an operator's provision(...) step — aeo does not ship a
# userland; it orchestrates one the operator populates. The nested_compose
# example declares dataset("zroot/jails/db"), so `setup-jail-root.sh db` is
# the prerequisite for `aeo up examples/nested_compose/module.ae`.
set -eu

if [ "${1:-}" = "--teardown" ]; then
    NAME="${2:-db}"
    jail -r "$NAME" 2>/dev/null || true
    zfs destroy -r "zroot/jails/$NAME" 2>/dev/null || true
    echo "torn down zroot/jails/$NAME"
    exit 0
fi

NAME="${1:-db}"
DATASET="zroot/jails/$NAME"
ROOT="/zroot/jails/$NAME"

# Create the dataset MOUNTED at $ROOT (not legacy), idempotent. A fresh
# `zfs create` under a legacy parent can come up legacy/unmounted, so set
# the mountpoint explicitly and mount it.
if ! zfs list "$DATASET" >/dev/null 2>&1; then
    zfs create -p "$DATASET"
fi
zfs set mountpoint="$ROOT" "$DATASET"
zfs mount "$DATASET" 2>/dev/null || true

# Populate: /rescue (static tools) + the dirs jail/jexec expect.
mkdir -p "$ROOT/rescue" "$ROOT/dev" "$ROOT/tmp" "$ROOT/bin" "$ROOT/etc"
cp -a /rescue/. "$ROOT/rescue/"
ln -sf /rescue/sh "$ROOT/bin/sh" 2>/dev/null || true

echo "jail root ready at $ROOT (rescue tools installed)"
echo "now:  sudo aeo up examples/nested_compose/module.ae   (db will boot)"
