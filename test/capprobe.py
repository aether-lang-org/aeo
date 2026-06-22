#!/usr/local/bin/python3
# capprobe.py <listener_host> <listener_port>
# Self-confining Capsicum probe: opens the ALLOWED channel (socket to the
# aeocha listener) FIRST, cap_enter()s, then attempts to-be-blocked ops in
# try/except and reports each result back over the allowed channel. The fact
# that the channel keeps working AFTER cap_enter proves "deny-except-this".
import sys, socket, ctypes, os

host, port = sys.argv[1], int(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)

# 1) ALLOWED CHANNEL — open BEFORE confinement (the one fd we keep usable).
sock = socket.create_connection((host, port), 5)
def report(line):
    sock.sendall((line + "\n").encode())

# 2) CONFINE SELF — irreversible cap_enter().
rc = libc.cap_enter()
report("CAP_ENTER rc=%d (0=ok)" % rc)
# confirm we are actually in capability mode
mode = ctypes.c_uint(0)
libc.cap_getmode(ctypes.byref(mode))
report("IN_CAPMODE %d" % mode.value)

# 3) ESCAPE ATTEMPTS in try/except — each should be BLOCKED by the kernel.
# fs-read: open a global path
try:
    open("/etc/passwd","r").read(1); report("fs-read ESCAPED")
except Exception as e:
    report("fs-read BLOCKED %s" % type(e).__name__)
# fs-write: create a new file
try:
    open("/tmp/jail-escape","w").write("x"); report("fs-write ESCAPED")
except Exception as e:
    report("fs-write BLOCKED %s" % type(e).__name__)
# tcpip-egress: NEW socket connect out
try:
    s2 = socket.socket(); s2.settimeout(3); s2.connect((host, port)); report("egress-newconn ESCAPED")
except Exception as e:
    report("egress-newconn BLOCKED %s" % type(e).__name__)
# tcpip-ingress: bind a listener
try:
    s3 = socket.socket(); s3.bind(("0.0.0.0", 0)); report("ingress-bind ESCAPED")
except Exception as e:
    report("ingress-bind BLOCKED %s" % type(e).__name__)

# 4) prove the ALLOWED channel STILL works post-confinement.
report("ALLOWED-CHANNEL still-open OK")
sock.close()
