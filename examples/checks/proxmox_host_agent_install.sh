#!/bin/sh
# proxmox_host_agent_install.sh — install aeo-agent ON the PVE HOST as a resident
# systemd listener, fetched from GitHub Releases (SHA-verified).
#
# WHY ssh, not 8006: the PVE 8006 API has NO host-shell endpoint — it manages VMs/
# storage/tasks, not "run this / install a unit on the hypervisor". And the least-
# priv deploy token is 403 on the host anyway (pool-scoped, deliberately blind to
# the host). So a host-resident agent is installed over SSH (root) — a higher-priv,
# separate channel from the deploy token, which is correct: putting a persistent
# agent on the hypervisor is a root-level host op, not something a VM-deploy token
# should ever do.
#
# "PRIVATE-KEY LISTENER": aeo-agent's own auth is a shared HMAC token, and its design
# intent is "ssh is the motorbike" (see lib/agent_auth) — SSH carries/protects the
# token. So the agent binds LOOPBACK (127.0.0.1) only; it is INVISIBLE to the network
# and reachable ONLY by someone with the root SSH key, who tunnels to it:
#     ssh -N -L 9460:127.0.0.1:9460 root@<pve>      # then POST http://127.0.0.1:9460/dispatch
# The SSH private key is the outer gate; the agent's token is the inner check.
#
# WHAT IT INSTALLS on the host:
#   /usr/local/bin/aeo-agent            the versioned binary (GH release, SHA-checked)
#   /etc/aeo/agent.env                  AEO_NODE / AEO_TOKEN / bind / port (0600)
#   /etc/systemd/system/aeo-agent.service   enabled + started, restarts, survives reboot
#
# Usage:
#   PVE_SSH=root@192.168.0.204 sh proxmox_host_agent_install.sh
#   PVE_SSH=root@192.168.0.204 sh proxmox_host_agent_install.sh --uninstall
#
# Env knobs:
#   PVE_SSH        ssh target (root@host). Required.
#   AEO_AGENT_VER  release tag to install (default aeo-agent-v0.1.2).
#   AEO_HOST_NODE  the agent's node identity (default the host's hostname).
#   AEO_HOST_PORT  loopback listen port (default 9460).
#   AEO_HOST_TOKEN the shared token (default: generated on the host, printed once).
set -eu

PVE_SSH="${PVE_SSH:?set PVE_SSH=root@<pve-host>}"
VER="${AEO_AGENT_VER:-aeo-agent-v0.1.2}"
ASSET="aeo-agent-linux-x86_64-static"
BASE="https://github.com/aether-lang-org/aeo/releases/download/${VER}"
PORT="${AEO_HOST_PORT:-9460}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 ${PVE_SSH}"

if [ "${1:-}" = "--uninstall" ]; then
    echo "[*] uninstalling aeo-agent host service on ${PVE_SSH}…" >&2
    $SSH 'systemctl disable --now aeo-agent 2>/dev/null || true
          rm -f /etc/systemd/system/aeo-agent.service /usr/local/bin/aeo-agent /etc/aeo/agent.env
          rmdir /etc/aeo 2>/dev/null || true
          systemctl daemon-reload 2>/dev/null || true
          echo "  removed."'
    exit 0
fi

# Resolve the pinned SHA from the release's published .sha256 (the CI workflow
# uploads it next to the binary) so the installer stays correct across versions
# without editing this file. Fail closed if it can't be fetched.
echo "[*] resolving ${VER} / ${ASSET} checksum…" >&2
SHA=$(curl -fsSL "${BASE}/${ASSET}.sha256" | awk '{print $1}')
[ -n "$SHA" ] || { echo "could not fetch ${ASSET}.sha256 for ${VER}"; exit 1; }
echo "    sha256=${SHA}" >&2

NODE="${AEO_HOST_NODE:-}"    # empty -> resolved to $(hostname) on the host below

# Everything runs ON THE HOST in one ssh so it's atomic and needs no local temp.
# The heredoc is unquoted-then-requoted carefully: we pass the few values we
# computed locally (BASE/ASSET/SHA/PORT/NODE/TOKEN) as env, and the host script
# does the fetch+verify+unit-write.
echo "[*] installing on ${PVE_SSH} (fetch + verify + systemd)…" >&2
$SSH "AEO_URL='${BASE}/${ASSET}' AEO_SHA='${SHA}' AEO_PORT='${PORT}' \
      AEO_NODE_IN='${NODE}' AEO_TOKEN_IN='${AEO_HOST_TOKEN:-}' sh -s" <<'REMOTE'
set -eu
node="${AEO_NODE_IN:-$(hostname)}"

# 1. FETCH the versioned agent + VERIFY sha (fail-closed).
curl -fsSL "$AEO_URL" -o /usr/local/bin/aeo-agent
echo "${AEO_SHA}  /usr/local/bin/aeo-agent" | sha256sum -c - \
  || { echo "SHA MISMATCH — refusing to install"; exit 1; }
chmod 0755 /usr/local/bin/aeo-agent
echo "  agent fetched + verified"

# 2. token: use the supplied one, else generate 32 hex bytes on the host.
token="${AEO_TOKEN_IN:-}"
[ -n "$token" ] || token=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')

# 3. env file (0600 — the token never sits on an argv / in the unit).
mkdir -p /etc/aeo
umask 077
cat > /etc/aeo/agent.env <<ENV
AEO_TRANSPORT=http
AEO_BIND=127.0.0.1
AEO_PORT=${AEO_PORT}
AEO_NODE=${node}
AEO_TOKEN=${token}
ENV
chmod 0600 /etc/aeo/agent.env
echo "  /etc/aeo/agent.env written (0600)"

# 4. systemd unit — loopback listener, restart-on-fail, boot-scoped.
cat > /etc/systemd/system/aeo-agent.service <<UNIT
[Unit]
Description=aeo-agent (host-resident listener, loopback only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/aeo/agent.env
ExecStart=/usr/local/bin/aeo-agent
Restart=on-failure
RestartSec=3
# hardening: the agent needs almost nothing from the host fs.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now aeo-agent
sleep 1
systemctl is-active aeo-agent >/dev/null 2>&1 && echo "  aeo-agent: ACTIVE (node=${node}, 127.0.0.1:${AEO_PORT})" \
  || { echo "  aeo-agent FAILED to start:"; journalctl -u aeo-agent -n 15 --no-pager; exit 1; }

# 5. print the token ONCE (so the operator can reach the listener via ssh tunnel).
echo "  token: ${token}"
REMOTE

cat >&2 <<EOF

[✓] aeo-agent installed as a host listener on ${PVE_SSH}.

    It binds 127.0.0.1:${PORT} only — invisible to the network. Reach it via an
    SSH tunnel (the private key is the gate; the token above is the inner check):

      ssh -N -L ${PORT}:127.0.0.1:${PORT} ${PVE_SSH} &
      curl -s -XPOST http://127.0.0.1:${PORT}/health          # -> ok
      curl -s -XPOST http://127.0.0.1:${PORT}/dispatch --data "boot <token> <node>"

    uninstall:  PVE_SSH=${PVE_SSH} sh $0 --uninstall
EOF
