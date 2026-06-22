#!/usr/local/bin/python3
# containment_harness_linux.py — host orchestrator. ssh into the Linux bhyve-VM
# guest, run the naive containment probe, capture its report (over the ssh pipe
# = the container-configured channel), emit REPORT <line> for aeocha. The probe
# is naive: it doesn't confine itself, it discovers the VM boundary by attempts.
import subprocess, sys
IP = sys.argv[1] if len(sys.argv) > 1 else "172.16.0.50"
KEY = "/home/paul/.ssh/id_rsa"
def gssh(cmd):
    return subprocess.run(["ssh","-i",KEY,"-o","StrictHostKeyChecking=no",
        "-o","UserKnownHostsFile=/dev/null","-o","ConnectTimeout=8",
        "ubuntu@"+IP, cmd], capture_output=True, text=True)
gssh("true")  # warm/clear known_hosts handled by opts
r = gssh("python3 /tmp/containment_probe_linux.py")
if not r.stdout:
    print("HARNESS_ERR", (r.stderr or "no output").strip()); sys.exit(2)
for line in r.stdout.splitlines():
    print("REPORT", line)
