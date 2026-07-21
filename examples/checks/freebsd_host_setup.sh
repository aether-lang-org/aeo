#!/bin/sh
# freebsd_host_setup.sh — one-time PREPARATION of a fresh FreeBSD/GhostBSD host
# for aeo's jail + bhyve substrates, over ssh. The FreeBSD peer of
# proxmox_bootstrap.sh.
#
# aeo does NOT need to be BUILT on the box: since aether v0.421.0, `ae build
# --target=x86_64-freebsd` cross-compiles the aeo binary on a Linux box (see
# aether-crossbuild for the base sysroot), and you scp it over. So the DEFAULT
# job of this script is HOST PREP only — the handful of privileged, box-shell
# steps a cross-built aeo can't do for itself:
#
#   1. NOPASSWD sudo for the invoking user (aeo's driver_bsd self-sudo path:
#      jail/jls/jexec/rctl/zfs run via `sudo -n`).
#   2. kern.racct.enable=1 in loader.conf — rctl resource caps need it; REQUIRES
#      A REBOOT (the script does NOT reboot for you — it prints the instruction).
#   3. THE GHOSTBSD GAP: GhostBSD 26 ships a slimmed base WITHOUT the jail/bhyve
#      userland (jail, jls, jexec, bhyve, bhyvectl, bhyveload). aeo's whole BSD
#      story needs them. They're NOT in any pkg + there's no pkgbase repo — so we
#      extract JUST those binaries from the stock FreeBSD base.txz that matches
#      `freebsd-version` EXACTLY (ABI-identical). A stock FreeBSD host already has
#      them and this step no-ops (guarded on `command -v jail`).
#
# The on-box AETHER TOOLCHAIN build (gmake, AE_CC=cc, base dev files) is the
# FALLBACK path, only if you must build aeo/ae ON the box — pass --with-toolchain.
# Prefer cross-building; it's why the FreeBSD --target work exists.
#
# Usage:
#   FBSD_SSH=paul@192.168.0.204 sh freebsd_host_setup.sh
#   FBSD_SSH=paul@192.168.0.204 sh freebsd_host_setup.sh --with-toolchain
#   FBSD_SSH=paul@192.168.0.204 sh freebsd_host_setup.sh --uninstall
#
# Env knobs:
#   FBSD_SSH        ssh target (user@host). Required.
#   FBSD_SUDO_PW    the user's password, for the ONE-TIME sudoers bootstrap over
#                   ssh (used with `sudo -S`; not stored). If unset and NOPASSWD
#                   isn't already active, the script says what to run by hand.
set -eu

FBSD_SSH="${FBSD_SSH:?set FBSD_SSH=user@host}"
MODE=setup
WITH_TOOLCHAIN=0
for a in "$@"; do
    case "$a" in
        --uninstall) MODE=uninstall ;;
        --with-toolchain) WITH_TOOLCHAIN=1 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

# Run a command on the box. `rsh <cmd>` = as the login user; `rsudo <cmd>` = via
# sudo -n (assumes NOPASSWD is already in place — true after step 1).
rsh()   { ssh -o BatchMode=yes "$FBSD_SSH" "$@"; }
rsudo() { ssh -o BatchMode=yes "$FBSD_SSH" "sudo -n $*"; }

user=$(printf '%s' "$FBSD_SSH" | sed 's/@.*//')

# --- uninstall -----------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
    echo "[*] removing aeo host prep from $FBSD_SSH (racct flag + sudoers drop-in)…" >&2
    rsudo "rm -f /usr/local/etc/sudoers.d/aeo-nopasswd" 2>/dev/null || true
    rsudo "sed -i '' '/kern.racct.enable/d' /boot/loader.conf" 2>/dev/null || true
    echo "    NB: extracted jail/bhyve binaries under /usr/sbin left in place (harmless);"
    echo "    remove by hand if desired. Reboot to drop the racct setting."
    exit 0
fi

echo "[*] aeo FreeBSD host setup <- $FBSD_SSH" >&2
osver=$(rsh 'freebsd-version' | tr -d '\r')
arch=$(rsh 'uname -m' | tr -d '\r')
# ae/zig --target uses x86_64/aarch64; FreeBSD's uname -m says amd64/arm64.
case "$arch" in
    amd64|x86_64)  tarch=x86_64 ;;
    arm64|aarch64) tarch=aarch64 ;;
    *) tarch="$arch" ;;
esac
echo "    host: FreeBSD $osver ($arch; --target arch $tarch)" >&2

# --- 1. NOPASSWD sudo -----------------------------------------------------------
if rsh 'sudo -n true' 2>/dev/null; then
    echo "[*] sudo NOPASSWD: already active" >&2
else
    if [ -n "${FBSD_SUDO_PW:-}" ]; then
        echo "[*] installing NOPASSWD sudoers drop-in (one-time, via password)…" >&2
        rsh "echo '$FBSD_SUDO_PW' | sudo -S sh -c '
            echo \"$user ALL=(ALL:ALL) NOPASSWD: ALL\" > /usr/local/etc/sudoers.d/aeo-nopasswd
            chmod 440 /usr/local/etc/sudoers.d/aeo-nopasswd'" 2>/dev/null
        rsh 'sudo -n true' 2>/dev/null && echo "    NOPASSWD active" >&2 \
            || { echo "    FAILED — check FBSD_SUDO_PW" >&2; exit 1; }
    else
        echo "    sudo needs a password and FBSD_SUDO_PW is unset. Run ONCE on the box:" >&2
        echo "      echo \"$user ALL=(ALL:ALL) NOPASSWD: ALL\" | sudo tee /usr/local/etc/sudoers.d/aeo-nopasswd" >&2
        echo "      sudo chmod 440 /usr/local/etc/sudoers.d/aeo-nopasswd" >&2
        exit 1
    fi
fi

# --- 2. rctl (kern.racct) — needs a reboot -------------------------------------
if [ "$(rsh 'sysctl -n kern.racct.enable 2>/dev/null' | tr -d '\r')" = "1" ]; then
    echo "[*] kern.racct.enable: already 1 (rctl live)" >&2
else
    echo "[*] enabling kern.racct.enable in /boot/loader.conf (rctl caps)…" >&2
    rsudo "sh -c 'grep -q kern.racct.enable /boot/loader.conf || echo kern.racct.enable=\\\"1\\\" >> /boot/loader.conf'"
    echo "    !! REBOOT REQUIRED for rctl: ssh $FBSD_SSH sudo shutdown -r now" >&2
    echo "    (re-run this script after the reboot to verify.)" >&2
fi

# --- 3. jail/bhyve userland (the GhostBSD gap) ---------------------------------
# GhostBSD 26 ships base WITHOUT these; extract them from the matching stock
# base.txz. Stock FreeBSD already has them -> this whole block no-ops.
NEED=""
for b in jail jls jexec bhyve bhyvectl bhyveload; do
    rsh "command -v $b >/dev/null 2>&1 || test -x /usr/sbin/$b" 2>/dev/null || NEED="$NEED $b"
done
if [ -z "$NEED" ]; then
    echo "[*] jail/bhyve userland: present" >&2
else
    rel=$(printf '%s' "$osver" | sed 's/-p[0-9]*$//')   # 15.0-RELEASE-p10 -> 15.0-RELEASE
    case "$arch" in
        amd64|x86_64) rdir=amd64 ;;
        arm64|aarch64) rdir="arm64/aarch64" ;;
        *) echo "    unsupported arch for base fetch: $arch" >&2; exit 1 ;;
    esac
    url="https://download.freebsd.org/releases/$rdir/$rel/base.txz"
    echo "[*] jail/bhyve userland MISSING ($NEED) — the GhostBSD slim-base gap." >&2
    echo "    extracting from the version-EXACT stock base: $url" >&2
    rsudo "sh -c '
        cd /tmp
        [ -f base-aeo.txz ] || fetch -q -o base-aeo.txz \"$url\"
        tar -xJf base-aeo.txz -C / \
            ./usr/sbin/jail ./usr/sbin/jls ./usr/sbin/jexec \
            ./usr/sbin/bhyve ./usr/sbin/bhyvectl ./usr/sbin/bhyveload
    '"
    # verify
    rsh 'test -x /usr/sbin/jail && test -x /usr/sbin/bhyve' \
        && echo "    installed: jail/jls/jexec + bhyve/bhyvectl/bhyveload" >&2 \
        || { echo "    extract FAILED" >&2; exit 1; }
fi

# --- 4. optional: on-box aether toolchain (FALLBACK — prefer cross-building) ----
if [ "$WITH_TOOLCHAIN" = 1 ]; then
    echo "[*] --with-toolchain: building ae ON the box (fallback path)…" >&2
    echo "    (cross-build is preferred: on Linux, ae build --target=$tarch-freebsd)" >&2
    rsudo "pkg install -y gmake git curl" >/dev/null 2>&1 || true
    # get.sh hardcodes BSD `make` on a GNU Makefile — fetch the tag tarball and
    # gmake-install by hand. AETHER_HOME=<prefix root>, AE_CC=cc are BOTH required.
    rsh 'sh -c "
        set -e
        mkdir -p ~/aebuild && cd ~/aebuild
        REF=\$(curl -fsSL https://api.github.com/repos/aether-lang-org/aether/tags?per_page=100 \
            | grep -o \"\\\"name\\\"[[:space:]]*:[[:space:]]*\\\"v[0-9][0-9.]*\\\"\" \
            | sed -n \"s/.*\\\"\\(v[0-9][0-9.]*\\)\\\".*/\\1/p\" \
            | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1)
        curl -fsSL \"https://github.com/aether-lang-org/aether/archive/\$REF.tar.gz\" -o ae.tar.gz
        tar -xzf ae.tar.gz && cd aether-*/
        gmake install PREFIX=\$HOME/.local CC=cc AE_CC=cc >/dev/null 2>&1
        printf \"export AETHER_HOME=\$HOME/.local\nexport AE_CC=cc\nexport CC=cc\nexport PATH=\$HOME/.local/bin:\\\$PATH\n\" > ~/aeoenv.sh
        echo built \$REF
    "' 2>&1 | tail -2
    echo "    toolchain env in ~/aeoenv.sh — \`. ~/aeoenv.sh\` before ae/aeo." >&2
fi

cat >&2 <<EOF

[✓] FreeBSD host prep done for $FBSD_SSH.

    jail + bhyve userland: present.  rctl: $(rsh 'sysctl -n kern.racct.enable 2>/dev/null' | tr -d '\r' | sed 's/1/enabled/;s/0/PENDING REBOOT/').

    NEXT — get the aeo binary onto the box (cross-build, the preferred path):
      # on a Linux box, with aether v0.421.0+ and an aether-crossbuild FreeBSD sysroot:
      AETHER_SYSROOT=<crossbuild>/bases/$tarch-freebsd15 \\
        ae build \$AEO_HOME/bin/aeo.ae -o /tmp/aeo-$tarch-freebsd --target=$tarch-freebsd --lib \$AEO_HOME/lib
      scp /tmp/aeo-$tarch-freebsd $FBSD_SSH:/tmp/aeo
      ssh $FBSD_SSH '/tmp/aeo doctor'   # should show: jail OK, bhyve OK

    Jail nodes also need a populated jail root (dataset + /rescue + /bin/sh); see
    docs/bsd-host-setup.md. Tear this prep down: sh $0 --uninstall
EOF
