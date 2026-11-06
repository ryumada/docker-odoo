#!/usr/bin/env python3
# Category: Test
# Description: Local stand-in for Google OAuth/Drive and the Odoo database manager, for tests/test_secret_args.sh.
#              Records every request (method, path, query, Authorization, transfer mode, form fields) as JSON lines.
# Usage: mock_http.py PORT_FILE LOG_FILE TOKEN   (binds a free port and writes it to PORT_FILE)
# Dependencies: python3
import email.parser, email.policy, http.server, json, sys, urllib.parse

port_file, log_file, token = sys.argv[1], sys.argv[2], sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def _body(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def _form(self, body):
        ctype = self.headers.get("Content-Type", "")
        if ctype.startswith("multipart/"):
            msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
                b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
            return {p.get_param("name", header="content-disposition"): p.get_payload(decode=True).decode("utf-8", "replace")
                    for p in msg.iter_parts()}
        return dict(urllib.parse.parse_qsl(body.decode("utf-8", "replace"), keep_blank_values=True))

    def _handle(self):
        url = urllib.parse.urlsplit(self.path)
        body = self._body() if self.command == "POST" else b""
        form = self._form(body)
        rec = {"method": self.command, "path": url.path, "query": url.query,
               "auth": self.headers.get("Authorization"), "chunked": self.headers.get("Transfer-Encoding") == "chunked",
               "form": form}
        with open(log_file, "a") as f:
            f.write(json.dumps(rec) + "\n")
        code, reply = 200, {"ok": True}
        if url.path == "/token":
            reply = {"access_token": token, "expires_in": 3599, "token_type": "Bearer"}
        elif url.path == "/tokeninfo":
            if form.get("access_token") == token:
                reply = {"expires_in": "3599", "scope": "https://www.googleapis.com/auth/drive"}
            else:
                code, reply = 400, {"error": "invalid_token"}
        data = json.dumps(reply).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = _handle

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
