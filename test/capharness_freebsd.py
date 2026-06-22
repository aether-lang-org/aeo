#!/usr/local/bin/python3
# capharness_freebsd.py — host orchestrator for the in-bhyve-VM Capsicum
# self-report. ssh into the FreeBSD guest (freebsd_vm), compile the probe with
# the guest's cc, run it; the confined guest process reports over stdout (its
# inherited allowed channel, survives cap_enter), which we capture over the ssh
# pipe. Prints REPORT <line> for the aeocha spec to assert on. The pf on the
# host blocks arbitrary aeonat->host ports, so stdout-over-ssh is the permitted
# channel (sshd:22 is reachable; high ports are not).
import subprocess, sys
IP = sys.argv[1] if len(sys.argv) > 1 else "172.16.0.50"
KEY = "/home/paul/.ssh/id_rsa"
SRC = "/tmp/capprobe_freebsd_stdout.c"
def gssh(cmd):
    return subprocess.run(["ssh","-i",KEY,"-o","StrictHostKeyChecking=no",
        "-o","UserKnownHostsFile=/dev/null","-o","ConnectTimeout=8",
        "freebsd@"+IP, cmd], capture_output=True, text=True)
# compile in guest + run; capture stdout (the self-report)
r = gssh("cc -o /tmp/cp %s 2>&1 && /tmp/cp" % SRC)
if r.returncode != 0 and not r.stdout:
    print("HARNESS_ERR", (r.stderr or r.stdout).strip()); sys.exit(2)
for line in r.stdout.splitlines():
    print("REPORT", line)
