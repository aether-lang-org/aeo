#!/usr/local/bin/python3
# capharness.py — host-side orchestrator the aeocha spec shells out to.
# Opens the aeocha LISTENER, spawns the self-confining probe INSIDE a FreeBSD
# jail, collects the reports the confined process sends back over the allowed
# channel, and prints them (KEY=VALUE) for aeocha to assert on. Self-contained:
# creates + tears down the jail. Exits 0 if the probe reported; nonzero on setup
# failure.
import socket, subprocess, sys, os

JID = "aeocapj"
PROBE = "/tmp/capprobe.py"

def sh(*a): return subprocess.run(a, capture_output=True, text=True)

# fresh jail (thin, shares host /, inherits host networking so the probe can
# reach the listener on 127.0.0.1).
sh("sudo","-n","jail","-r",JID)
c = sh("sudo","-n","jail","-c","name="+JID,"path=/","host.hostname="+JID,"ip4=inherit","persist")
if "error" in (c.stderr or "").lower():
    print("HARNESS_ERR jail-create:", c.stderr.strip()); sys.exit(2)

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
srv.settimeout(30)

p = subprocess.Popen(["sudo","-n","jexec",JID,"python3",PROBE,"127.0.0.1",str(port)])
reports = b""
try:
    conn, _ = srv.accept()
    while True:
        b = conn.recv(4096)
        if not b: break
        reports += b
except socket.timeout:
    print("HARNESS_ERR probe-never-connected")
finally:
    sh("sudo","-n","jail","-r",JID)

# emit the confined process's self-report for aeocha to assert on
for line in reports.decode().splitlines():
    print("REPORT", line)
