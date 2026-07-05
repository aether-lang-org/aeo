# srv-srcip.py — a minimal source-IP echo server for the pasta external-arm test.
# Logs `PEER=<client_address[0]>` for every GET: the peer IP the container actually
# sees. Used to prove whether pasta+pesto preserves a remote client's real source IP
# (see TODO.md "PROVE THE EXTERNAL ARM" + docs/linux-host-setup.md).
#
#   podman run -d --name srctest --network <bridge> -p 8099:8099 \
#       -v $PWD/test/srv-srcip.py:/srv.py:ro python:3-alpine python /srv.py
#   # then, FROM A SECOND HOST on the LAN:  curl http://<box-LAN-IP>:8099/
#   podman logs srctest        # PASS: PEER=<2nd host LAN IP>; FAIL: PEER=169.254.x
import http.server, socketserver

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print("PEER=" + self.client_address[0], flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass

socketserver.TCPServer(("0.0.0.0", 8099), H).serve_forever()
