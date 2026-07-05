#!/bin/sh
# aeo-supervisor-install.sh — install aeo-supervisord as a boot service, per the
# host's init system. Cross-init: systemd, OpenRC (Alpine/Gentoo), FreeBSD rc.d.
# Restart=NO everywhere (docs/aeo-supervisor.md): if the supervisor crashes, ops
# reboots the box — we do NOT auto-restart it into a boot whose tree it lost.
#
#   sudo AEO_SUP_BIN=/usr/local/bin/aeo-supervisord \
#        AEO_SUP_TOKEN=<token> sh bin/aeo-supervisor-install.sh [--start]
#
# AEO_SUP_BIN   path to the built aeo-supervisord (required)
# AEO_SUP_TOKEN the shared token the front-door will present (required; fail-closed)
# AEO_SUP_BIND  bind address (default 127.0.0.1)
# AEO_SUP_PORT  port (default 9460)
# --start       also start the service now (else just install + enable)

set -eu
BIN="${AEO_SUP_BIN:?set AEO_SUP_BIN to the aeo-supervisord path}"
TOKEN="${AEO_SUP_TOKEN:?set AEO_SUP_TOKEN (the shared secret; fail-closed)}"
BIND="${AEO_SUP_BIND:-127.0.0.1}"
PORT="${AEO_SUP_PORT:-9460}"
START=0
[ "${1:-}" = "--start" ] && START=1
[ -x "$BIN" ] || { echo "aeo-supervisor-install: $BIN is not executable"; exit 1; }

# --- detect the init system ---------------------------------------------------
detect_init() {
  if [ "$(uname -s)" = "FreeBSD" ] || [ "$(uname -s)" = "OpenBSD" ] || [ "$(uname -s)" = "NetBSD" ]; then
    echo rcd; return
  fi
  # systemd: PID 1 is systemd, or systemctl drives it
  if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    echo systemd; return
  fi
  if command -v rc-update >/dev/null 2>&1; then echo openrc; return; fi
  echo unknown
}
INIT="$(detect_init)"
echo "aeo-supervisor-install: init=$INIT bin=$BIN bind=$BIND port=$PORT"

case "$INIT" in
  systemd)
    UNIT=/etc/systemd/system/aeo-supervisor.service
    cat > "$UNIT" <<EOF
[Unit]
Description=aeo-supervisor — resident holder of this-boot's aeo trees
After=network.target

[Service]
Type=simple
Environment=AEO_SUP_TOKEN=$TOKEN
Environment=AEO_SUP_BIND=$BIND
Environment=AEO_SUP_PORT=$PORT
ExecStart=$BIN
# Restart=no BY DESIGN — a crash is an OS-level event; ops reboots. We must NOT
# resurrect the supervisor into a boot whose tree it no longer holds.
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable aeo-supervisor.service
    [ "$START" = 1 ] && systemctl start aeo-supervisor.service || true
    echo "installed $UNIT (enabled)."
    ;;

  openrc)
    SVC=/etc/init.d/aeo-supervisor
    cat > "$SVC" <<EOF
#!/sbin/openrc-run
name="aeo-supervisor"
description="resident holder of this-boot's aeo trees"
command="$BIN"
command_background=true
pidfile="/run/aeo-supervisor.pid"
export AEO_SUP_TOKEN="$TOKEN"
export AEO_SUP_BIND="$BIND"
export AEO_SUP_PORT="$PORT"
# no respawn: a crash is an OS-level event (see docs/aeo-supervisor.md).
depend() { need net; }
EOF
    chmod +x "$SVC"
    rc-update add aeo-supervisor default
    [ "$START" = 1 ] && rc-service aeo-supervisor start || true
    echo "installed $SVC (added to default runlevel)."
    ;;

  rcd)
    SVC=/usr/local/etc/rc.d/aeo_supervisor
    cat > "$SVC" <<EOF
#!/bin/sh
# PROVIDE: aeo_supervisor
# REQUIRE: NETWORKING
# KEYWORD: shutdown
. /etc/rc.subr
name="aeo_supervisor"
rcvar="aeo_supervisor_enable"
command="$BIN"
# daemon(8) WITHOUT -r: no restart-on-crash (a crash -> ops reboots; see
# docs/aeo-supervisor.md). -f detaches; -P records the pid.
command_interpreter=""
pidfile="/var/run/aeo_supervisor.pid"
start_cmd="aeo_supervisor_start"
aeo_supervisor_start() {
    export AEO_SUP_TOKEN="$TOKEN"
    export AEO_SUP_BIND="$BIND"
    export AEO_SUP_PORT="$PORT"
    /usr/sbin/daemon -f -P \$pidfile $BIN
    echo "aeo_supervisor started."
}
load_rc_config \$name
: \${aeo_supervisor_enable:="NO"}
run_rc_command "\$1"
EOF
    chmod +x "$SVC"
    sysrc aeo_supervisor_enable=YES >/dev/null
    [ "$START" = 1 ] && service aeo_supervisor start || true
    echo "installed $SVC (enabled via rc.conf)."
    ;;

  *)
    echo "aeo-supervisor-install: unknown init system — install the service by hand."
    echo "  run: AEO_SUP_TOKEN=$TOKEN AEO_SUP_BIND=$BIND AEO_SUP_PORT=$PORT $BIN"
    exit 1
    ;;
esac

echo "aeo-supervisor: installed. The front-door will adopt into it (AEO_SUP_TOKEN must match)."
