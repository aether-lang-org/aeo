# The /add service: GET /add/<a>/<b> -> a+b, cached in redis (REDIS_HOST).
# Stock-library only (no pip) so it runs on python:3-alpine.
import http.server as h, socket, os
RHOST = os.environ.get("REDIS_HOST", "127.0.0.1")
def rcmd(*a):
    s = socket.create_connection((RHOST, 6379), 1)
    s.sendall(("*%d\r\n" % len(a) + "".join("$%d\r\n%s\r\n" % (len(x), x) for x in a)).encode())
    r = s.recv(4096); s.close(); return r
class A(h.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path.strip("/").split("/")
        try:
            k = "add:%s:%s" % (p[1], p[2]); c = rcmd("GET", k)
            if c[:1] == b"$" and c[1:2] != b"-": b = c.split(b"\r\n")[1].decode()
            else: b = str(int(p[1]) + int(p[2])); rcmd("SET", k, b)
        except Exception: b = "err"
        self.send_response(200); self.end_headers(); self.wfile.write(b.encode())
    def log_message(self, *a): pass
h.HTTPServer(("0.0.0.0", 8080), A).serve_forever()
