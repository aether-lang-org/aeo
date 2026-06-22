#!/usr/bin/env python3
# containment_probe_linux.py — a NAIVE process inside a Linux bhyve-VM guest.
# Per principles-of-containment: it does NOT confine itself, does not know it is
# contained. It ATTEMPTS to reach HOST-side things (outside the VM boundary) and
# DISCOVERS containment by what it cannot reach. It reports findings back over
# the ONE channel the container configured for it — here, stdout captured via
# the ssh pipe (ssh/:22 is the host-configured inbound; arbitrary host ports are
# NOT reachable precisely because the container didn't open them).
#
# Container = the bhyve VM boundary (implicit, no extra config): the guest's
# world is its own kernel/fs; the host's files, processes, host-only loopback
# services are simply not present/reachable.
import os, socket, subprocess
def report(line): print(line, flush=True)

report("GUEST uname=%s" % os.uname().sysname)

report("host-bhyve-binary " + ("REACHED" if os.path.exists("/usr/sbin/bhyve") else "CONTAINED"))
report("host-freebsd-passwd " + ("REACHED" if os.path.exists("/etc/master.passwd") else "CONTAINED"))
try:
    ps = subprocess.run(["ps","ax"], capture_output=True, text=True).stdout
    report("host-bhyve-process " + ("REACHED" if "bhyve" in ps else "CONTAINED"))
    report("guest-pid-count %d" % len(ps.strip().splitlines()))
except Exception as e:
    report("host-bhyve-process ERR %s" % type(e).__name__)
# the host gateway's OWN sshd (172.16.0.1:22) is reachable (configured); an
# arbitrary host port (8911) is NOT — the container didn't open it.
def reachable(ipport):
    try:
        s=socket.socket(); s.settimeout(3); s.connect(ipport); s.close(); return True
    except Exception: return False
report("host-configured-port-22 " + ("REACHED" if reachable(("172.16.0.1",22)) else "CONTAINED"))
report("host-unconfigured-port-8911 " + ("REACHED" if reachable(("172.16.0.1",8911)) else "CONTAINED"))
report("CONFIGURED-CHANNEL ok")
