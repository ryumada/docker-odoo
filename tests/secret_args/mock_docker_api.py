#!/usr/bin/env python3
# Category: Test
# Description: Minimal Docker Engine API stand-in for tests/test_secret_args.sh: the real docker client talks to it,
#              and it records the environment of each container create / exec request, then refuses to run anything.
# Usage: mock_docker_api.py PORT_FILE LOG_FILE   (binds a free port and writes it to PORT_FILE)
# Dependencies: python3
import http.server, json, re, sys

port_file, log_file = sys.argv[1], sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Api-Version", "1.44")
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self._send(200, b"OK", "text/plain")

    def do_GET(self):
        if self.path.endswith("/_ping"):
            return self._send(200, b"OK", "text/plain")
        m = re.search(r"/containers/([^/]+)/json", self.path)
        if m:
            return self._send(200, json.dumps({"Id": m.group(1), "State": {"Running": True, "Status": "running"},
                                               "Config": {}}).encode())
        self._send(404, b'{"message":"not mocked"}')

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if re.search(r"/containers/(create|[^/]+/exec)$", self.path.split("?")[0]):
            with open(log_file, "a") as f:
                f.write(json.dumps({"path": self.path, "env": json.loads(body or b"{}").get("Env") or []}) + "\n")
        self._send(500, b'{"message":"mock docker: nothing is run"}')

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
