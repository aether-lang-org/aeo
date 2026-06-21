#!/bin/sh
# soup-to-nuts.sh — THE end-to-end experience, driven by the aeo DSL.
#
# Runs `aeo up examples/nested_compose/module.ae` — which brings up the whole
# nested system declared in the DSL:
#
#   system("red222")
#     └─ myapp (bhyve Linux VM)
#          ├─ db  (redis container — a TCP cache)
#          └─ app (python container) ── depends ──► db
#
# then curls the app FROM the FreeBSD host and asserts the two-tier behaviour
# (compute on a miss, serve from the redis cache on a hit). This is the real
# soup-to-nuts: the DSL is the source of truth; aeo provisions + boots the VM
# (AMD-safe image + static IP), builds+runs both containers inside it over
# ssh, and the service answers the host.
#
#   sudo sh test/soup-to-nuts.sh
#
# ONE-TIME prerequisites (the operator provisions the substrate; aeo
# orchestrates it). The script checks for them and tells you what's missing:
#   sudo sh test/setup-nat.sh           # NAT switch + dnsmasq + linux-nat tmpl
#   sudo sh test/patch-amd-image.sh     # jammy-amd.img (AMD Ryzen boot fix)
# (podman lands in the guest via the golden base or cloud-init.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEO="${AEO:-/tmp/aeo}"
DSL="$ROOT/examples/nested_compose/module.ae"
GIP="${GIP:-172.16.0.50}"

echo "=== prerequisite check ==="
miss=0
[ -f /zroot/vm/.img/jammy-amd.img ] || { echo "  MISSING: jammy-amd.img  -> sudo sh test/patch-amd-image.sh"; miss=1; }
vm switch list 2>/dev/null | grep -q aeonat || { echo "  MISSING: NAT switch    -> sudo sh test/setup-nat.sh"; miss=1; }
[ -x "$AEO" ] || { echo "  MISSING: aeo binary at $AEO -> ae build bin/aeo.ae -o /tmp/aeo --lib lib"; miss=1; }
[ "$miss" = 0 ] && echo "  all present" || { echo "fix the above, then re-run"; exit 1; }

echo "=== aeo up (the DSL drives everything) ==="
AEO_HOME="$ROOT" "$AEO" up "$DSL" 2>&1 | sed 's/^/  /'

echo "=== THE soup-to-nuts curl: host -> app (in the VM) -> db (redis) ==="
a=$(curl -fsS -m 8 "http://$GIP:8080/add/2/3"  2>/dev/null)
b=$(curl -fsS -m 8 "http://$GIP:8080/add/40/2" 2>/dev/null)
echo "  /add/2/3  = $a   (expect 5)"
echo "  /add/40/2 = $b   (expect 42)"

echo "=== prove the cache: overwrite db, re-request, expect the CACHED value ==="
ssh -i /home/paul/.ssh/id_rsa -o StrictHostKeyChecking=no ubuntu@"$GIP" \
    'podman exec db redis-cli SET add:2:3 CACHED99 >/dev/null 2>&1' 2>/dev/null
c=$(curl -fsS -m 8 "http://$GIP:8080/add/2/3" 2>/dev/null)
echo "  /add/2/3 after cache poke = $c   (expect CACHED99 — proves app read db)"

if [ "$a" = "5" ] && [ "$b" = "42" ] && [ "$c" = "CACHED99" ]; then
    echo "=== PASS: two-tier nested system, DSL-driven, curl-proven ==="
    exit 0
fi
echo "=== FAIL ==="; exit 1
