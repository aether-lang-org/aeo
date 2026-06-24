#!/bin/sh
# converge-nested.sh — SUPERSEDED. Use test/soup-to-nuts.sh instead.
#
# This script bypasses the DSL (it hardcodes the app + ssh's into the guest
# itself). The real soup-to-nuts experience is now DSL-driven:
#   sudo sh test/soup-to-nuts.sh   ->  aeo up examples/silly_addition_cache + curl
# Kept for reference only.
#
# Runs ON the FreeBSD host. Proves the full nested chain end-to-end:
#   a Linux container (the Python /add arithmetic service) running INSIDE
#   the bhyve Ubuntu guest (provisioned by aeo's vm-bhyve driver), reachable
#   FROM the FreeBSD host across the VM boundary.
#
#   sudo sh test/converge-nested.sh         # assumes aeo-guest is up + networked
#
# This mirrors what the runner / aeo-agent will do automatically (ssh into
# the guest VM, stage the app, podman build+run, publish the port); here
# it's a script so the proven flow is reproducible + committed. The guest
# is brought up by aeo's bhyve driver (bhyve_up → vm-bhyve, cloud-init
# installs podman + auto-networks — see lib/driver_vm + memory
# bhyve-guest-networking).
set -eu

KEY="${KEY:-/home/paul/.ssh/id_rsa}"
GUEST_USER="${GUEST_USER:-ubuntu}"

# Find the guest IP from its MAC via ARP (the driver knows this too).
MAC=$(grep -o 'network0_mac="[^"]*"' /zroot/vm/aeo-guest/aeo-guest.conf | cut -d'"' -f2)
for n in $(seq 200 250); do ping -c1 -W1 192.168.0.$n >/dev/null 2>&1 & done; wait
GIP=$(arp -a 2>/dev/null | grep -i "$MAC" | grep -oE '192.168.0.[0-9]+' | head -1)
[ -n "$GIP" ] || { echo "FAIL: guest aeo-guest has no IP (is it up + networked?)"; exit 1; }
echo "guest aeo-guest at $GIP"

SSHG="ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 $GUEST_USER@$GIP"

# The Python /add service (stdlib, no pip) — the workload.
cat > /tmp/app.py <<'PY'
import http.server as h
class A(h.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path.strip("/").split("/")
        try: b = str(int(p[1]) + int(p[2]))
        except: b = "err"
        self.send_response(200); self.end_headers(); self.wfile.write(b.encode())
    def log_message(self, *a): pass
h.HTTPServer(("0.0.0.0", 8080), A).serve_forever()
PY
cat > /tmp/Dockerfile.app <<'DF'
FROM docker.io/library/python:3-alpine
COPY app.py /app.py
CMD ["python", "/app.py"]
DF

echo "=== stage app into the guest + build/run it there (podman, publish 8080) ==="
scp -i "$KEY" -o StrictHostKeyChecking=no /tmp/app.py /tmp/Dockerfile.app "$GUEST_USER@$GIP:/home/$GUEST_USER/"
$SSHG "cd /home/$GUEST_USER && podman build -t aeo-app -f Dockerfile.app . >/dev/null && podman rm -f app >/dev/null 2>&1; podman run -d --name app -p 8080:8080 aeo-app >/dev/null && sleep 2 && echo in-guest: \$(curl -fsS http://localhost:8080/add/2/3)"

echo "=== CONVERGENCE: curl the in-guest service FROM THE FREEBSD HOST ==="
A=$(curl -fsS "http://$GIP:8080/add/2/3"); echo "  host->guest /add/2/3 = $A"
B=$(curl -fsS "http://$GIP:8080/add/40/2"); echo "  host->guest /add/40/2 = $B"
[ "$A" = "5" ] && [ "$B" = "42" ] && echo "=== PASS: Linux container in bhyve VM on FreeBSD, computed over HTTP ===" || { echo "FAIL"; exit 1; }
