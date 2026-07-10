#!/usr/bin/env python3
# egress_splice_harness.py — LIVE end-to-end proof of egress_relay.splice through
# the real bin/aeo-egress-gateway binary. Started by spec_egress_splice_live.ae.
#
# Stands up a loopback echo upstream, points the gateway's allowlist at it, then
# runs two CONNECT clients:
#   1. FULL-DUPLEX: write three chunks BEFORE reading any echo (a burst the old
#      half-duplex lockstep pump would deadlock on), then drain all three echoes.
#   2. DENY: a non-allowlisted host must be refused with 403 at the CONNECT line,
#      before any tunnel/splice.
#
# Prints one RESULT line per check (RESULT <name> PASS|FAIL ...) and a final
# RESULT summary PASS|FAIL. Exit 0 iff every check passed. The .ae spec parses
# these lines. Self-contained: only stdlib + the gateway binary path in argv.
import os, socket, subprocess, sys, threading, time

GW_BIN = sys.argv[1]              # path to the built aeo-egress-gateway
UP_PORT = int(sys.argv[2])
GW_PORT = int(sys.argv[3])

results = []
def record(name, ok, detail=""):
    results.append(ok)
    print(f"RESULT {name} {'PASS' if ok else 'FAIL'} {detail}", flush=True)

# ---- echo upstream (a plain TCP echo; the true endpoint behind the tunnel) ----
def echo_server(port, ready):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(8)
    ready.set()
    def h(c):
        try:
            while True:
                d = c.recv(65536)
                if not d: break
                c.sendall(d)
        except OSError:
            pass
        finally:
            c.close()
    while True:
        try:
            c, _ = s.accept()
        except OSError:
            break
        threading.Thread(target=h, args=(c,), daemon=True).start()

def connect_head(sock, authority):
    sock.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
    resp = b""
    sock.settimeout(5)
    while b"\r\n\r\n" not in resp:
        d = sock.recv(1024)
        if not d: break
        resp += d
    return resp.split(b"\r\n")[0] if resp else b""

def check_fullduplex():
    try:
        s = socket.create_connection(("127.0.0.1", GW_PORT), timeout=5)
        line0 = connect_head(s, f"127.0.0.1:{UP_PORT}")
        if b"200" not in line0:
            record("fullduplex", False, f"connect not 200: {line0!r}"); s.close(); return
        # BURST: three writes before any read.
        for m in (b"alpha-0001", b"bravo-0002", b"charlie-03"):
            s.sendall(m)
        got = b""; s.settimeout(4)
        try:
            while len(got) < 30:
                d = s.recv(65536)
                if not d: break
                got += d
        except socket.timeout:
            pass
        s.close()
        ok = all(x in got for x in (b"alpha-0001", b"bravo-0002", b"charlie-03"))
        record("fullduplex", ok, f"got={got.decode(errors='replace')}")
    except Exception as e:
        record("fullduplex", False, f"exc={e!r}")

def check_deny():
    try:
        s = socket.create_connection(("127.0.0.1", GW_PORT), timeout=5)
        line0 = connect_head(s, "evil.example.com:443")
        s.close()
        record("deny", b"403" in line0, f"line={line0.decode(errors='replace')}")
    except Exception as e:
        record("deny", False, f"exc={e!r}")

def main():
    ready = threading.Event()
    threading.Thread(target=echo_server, args=(UP_PORT, ready), daemon=True).start()
    ready.wait(5)

    # Gateway: allowlist the echo host only; bind the gateway port.
    env = dict(os.environ)
    env["AEO_EGRESS_ALLOW"] = "127.0.0.1"
    env["AEO_EGRESS_HOST"] = "127.0.0.1"
    env["AEO_EGRESS_PORT"] = str(GW_PORT)
    gw = subprocess.Popen([GW_BIN], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        # wait for the listening banner
        deadline = time.time() + 8
        while time.time() < deadline:
            line = gw.stdout.readline()
            if not line: break
            if b"listening" in line:
                break
        time.sleep(0.2)
        check_fullduplex()
        check_deny()
    finally:
        gw.terminate()
        try:
            gw.wait(timeout=3)
        except subprocess.TimeoutExpired:
            gw.kill()

    ok = all(results) and len(results) == 2
    print(f"RESULT summary {'PASS' if ok else 'FAIL'}", flush=True)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
