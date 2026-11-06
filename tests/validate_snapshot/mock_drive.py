#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Category: Test
Module: tests/validate_snapshot/mock_drive.py
Purpose: Mock Google Drive v3 API for the validate-snapshot tests (list, download, upload, delete, /token).
"""
# Usage:
#   mock_drive.py serve --root DIR          serve on 127.0.0.1, OS-chosen port written to DIR/port
#   mock_drive.py seed --root DIR --name N [--folder F] [--created ISO] --file PATH   add a file, prints its id
# Every request needs "Authorization: Bearer $MOCK_TOKEN" (except POST /token, which takes a
# service-account JWT assertion and answers with $MOCK_TOKEN). Each request is logged to
# DIR/requests.log as "METHOD PATH auth=ok|BAD"; the last assertion is kept in DIR/last_assertion.
# Files are DIR/files/<id>.json (metadata) + DIR/files/<id>.bin (content); state is re-read per request.

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def files_dir(root):
    d = os.path.join(root, "files")
    os.makedirs(d, exist_ok=True)
    return d


def load_all(root):
    out = []
    d = files_dir(root)
    for n in os.listdir(d):
        if n.endswith(".json"):
            with open(os.path.join(d, n)) as f:
                out.append(json.load(f))
    return out


def save_file(root, name, data, parents, created=None):
    d = files_dir(root)
    fid = "f%d%04d" % (time.time_ns() // 1000, len(os.listdir(d)))
    meta = {"id": fid, "name": name, "parents": parents or [], "trashed": False,
            "createdTime": created or time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            "size": str(len(data)), "sha256Checksum": hashlib.sha256(data).hexdigest()}
    with open(os.path.join(d, fid + ".bin"), "wb") as f:
        f.write(data)
    with open(os.path.join(d, fid + ".json"), "w") as f:
        json.dump(meta, f)
    return meta


def parse_q(q):
    """Supports the clauses the scripts send, joined by ' and '."""
    tests = []
    for clause in re.findall(r"(name contains '(?:[^'\\]|\\.)*'|name = '(?:[^'\\]|\\.)*'|trashed = (?:true|false)|'[^']*' in parents)", q):
        m = re.match(r"name (contains|=) '(.*)'$", clause)
        if m:
            val = m.group(2).replace("\\'", "'").replace("\\\\", "\\")
            if m.group(1) == "contains":
                tests.append(lambda f, v=val: v in f["name"])
            else:
                tests.append(lambda f, v=val: f["name"] == v)
            continue
        m = re.match(r"trashed = (true|false)$", clause)
        if m:
            tests.append(lambda f, v=(m.group(1) == "true"): bool(f.get("trashed")) == v)
            continue
        m = re.match(r"'([^']*)' in parents$", clause)
        if m:
            tests.append(lambda f, v=m.group(1): v in f.get("parents", []))
    return tests


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _authorized(self, path):
        ok = self.headers.get("Authorization", "") == "Bearer " + os.environ.get("MOCK_TOKEN", "")
        with LOCK, open(os.path.join(self.server.root, "requests.log"), "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, path, "ok" if ok else "BAD"))
        if not ok:
            self._send(401, {"error": {"code": 401, "message": "Invalid Credentials"}})
        return ok

    def _route(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        return u.path, qs

    def do_POST(self):
        path, qs = self._route()
        root = self.server.root
        if path == "/token":
            form = urllib.parse.parse_qs(self._body().decode())
            with LOCK, open(os.path.join(root, "requests.log"), "a") as f:
                f.write("POST /token auth=assertion\n")
            assertion = (form.get("assertion") or [""])[0]
            grant = (form.get("grant_type") or [""])[0]
            with open(os.path.join(root, "last_assertion"), "w") as f:
                f.write(assertion)
            if grant != "urn:ietf:params:oauth:grant-type:jwt-bearer" or assertion.count(".") != 2:
                return self._send(400, {"error": "invalid_grant"})
            return self._send(200, {"access_token": os.environ.get("MOCK_TOKEN", ""), "expires_in": 3599,
                                    "token_type": "Bearer"})
        if not self._authorized(path):
            return
        if path == "/upload/drive/v3/files":
            ctype = self.headers.get("Content-Type", "")
            m = re.search(r"boundary=([^;]+)", ctype)
            if not m:
                return self._send(400, {"error": {"message": "no boundary"}})
            boundary = m.group(1).strip().encode()
            parts = [p for p in self._body().split(b"--" + boundary) if p.strip() not in (b"", b"--")]
            if len(parts) < 2:
                return self._send(400, {"error": {"message": "need metadata and content"}})

            def payload(p):
                head, _, body = p.partition(b"\r\n\r\n")
                return body[:-2] if body.endswith(b"\r\n") else body
            meta = json.loads(payload(parts[0]))
            with LOCK:
                rec = save_file(root, meta["name"], payload(parts[1]), meta.get("parents"))
            return self._send(200, {"id": rec["id"], "name": rec["name"]})
        self._send(404, {"error": {"message": "not found"}})

    def do_GET(self):
        path, qs = self._route()
        root = self.server.root
        if not self._authorized(path):
            return
        if path == "/drive/v3/files":
            files = load_all(root)
            for t in parse_q((qs.get("q") or [""])[0]):
                files = [f for f in files if t(f)]
            if (qs.get("orderBy") or [""])[0] == "createdTime desc":
                files.sort(key=lambda f: f["createdTime"], reverse=True)
            else:
                files.sort(key=lambda f: f["id"])
            size = int((qs.get("pageSize") or ["100"])[0])
            start = int((qs.get("pageToken") or ["0"])[0])
            page = files[start:start + size]
            out = {"files": [{k: f[k] for k in ("id", "name", "size", "createdTime", "sha256Checksum")} for f in page]}
            if start + size < len(files):
                out["nextPageToken"] = str(start + size)
            return self._send(200, out)
        m = re.match(r"^/drive/v3/files/([A-Za-z0-9]+)$", path)
        if m:
            meta_p = os.path.join(files_dir(root), m.group(1) + ".json")
            if not os.path.exists(meta_p):
                return self._send(404, {"error": {"code": 404, "message": "File not found"}})
            with open(meta_p) as f:
                meta = json.load(f)
            if (qs.get("alt") or [""])[0] == "media":
                with open(os.path.join(files_dir(root), m.group(1) + ".bin"), "rb") as f:
                    return self._send(200, f.read(), "application/octet-stream")
            return self._send(200, meta)
        self._send(404, {"error": {"message": "not found"}})

    def do_DELETE(self):
        path, _ = self._route()
        if not self._authorized(path):
            return
        m = re.match(r"^/drive/v3/files/([A-Za-z0-9]+)$", path)
        d = files_dir(self.server.root)
        if m and os.path.exists(os.path.join(d, m.group(1) + ".json")):
            with LOCK:
                for ext in (".json", ".bin"):
                    os.remove(os.path.join(d, m.group(1) + ext))
            return self._send(204, b"")
        self._send(404, {"error": {"code": 404, "message": "File not found"}})

    def do_PATCH(self):
        path, _ = self._route()
        if not self._authorized(path):
            return
        body = self._body()
        m = re.match(r"^/drive/v3/files/([A-Za-z0-9]+)$", path)
        p = os.path.join(files_dir(self.server.root), (m.group(1) if m else "x") + ".json")
        if not m or not os.path.exists(p):
            return self._send(404, {"error": {"code": 404, "message": "File not found"}})
        with LOCK:
            with open(p) as f:
                meta = json.load(f)
            try:
                meta.update({k: v for k, v in json.loads(body or b"{}").items() if k == "trashed"})
            except ValueError:
                pass
            with open(p, "w") as f:
                json.dump(meta, f)
        self._send(200, meta)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["serve", "seed"])
    ap.add_argument("--root", required=True)
    ap.add_argument("--name")
    ap.add_argument("--folder")
    ap.add_argument("--created")
    ap.add_argument("--file")
    a = ap.parse_args()
    os.makedirs(a.root, exist_ok=True)
    if a.mode == "seed":
        with open(a.file, "rb") as f:
            rec = save_file(a.root, a.name, f.read(), [a.folder] if a.folder else [], a.created)
        print(rec["id"])
        return
    if not os.environ.get("MOCK_TOKEN"):
        sys.exit("MOCK_TOKEN is not set")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.daemon_threads = True
    srv.root = a.root
    tmp = os.path.join(a.root, "port.tmp")
    with open(tmp, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, os.path.join(a.root, "port"))
    srv.serve_forever()


if __name__ == "__main__":
    main()
