#!/usr/bin/env python3
"""A thin front for the rig's fake Graph drive: it answers `GET /v1.0/me` (who the account is) and forwards
every other request, headers and body as they are, to the drive.

Why: the Microsoft family reads `/v1.0/me` first when a sign-in finishes (microsoft/graph.rs `whoami`), and
porter-fake-servers' FakeGraph is a drive only (it answers 404), so no Microsoft account can be added against it.
The ask for porter is a `/v1.0/me` route in FakeGraph (or in porter-rig-servers --graph); this front goes when it
lands. The front accepts the account only when the drive does: it asks the drive for `/v1.0/me/drive` with the
same Authorization before it answers.

  graph-front.py --upstream http://127.0.0.1:PORT --port-file FILE [--mail ada@outlook.rig.test]

Binds 127.0.0.1 on a free port, writes the port to FILE once listening, runs until killed.  Run with -I."""
import argparse
import http.client
import json
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

args = None


class Front(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _upstream(self, method, target, headers, body):
        u = urlsplit(args.upstream)
        c = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
        c.request(method, target, body=body, headers=headers)
        r = c.getresponse()
        return r.status, r.getheaders(), r.read()

    def _send(self, status, headers, body):
        self.send_response(status)
        sent_len = False
        for k, v in headers:
            if k.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        if self.command == "GET" and self.path.split("?")[0] == "/v1.0/me":
            status, _h, _b = self._upstream("GET", "/v1.0/me/drive", headers, None)
            if status == 200:
                doc = json.dumps({"mail": args.mail, "userPrincipalName": args.mail, "displayName": "Ada"}).encode()
                self._send(200, [("Content-Type", "application/json")], doc)
            else:
                self._send(status, [("Content-Type", "application/json")], b'{"error":{"code":"InvalidAuthenticationToken"}}')
            return
        status, hs, b = self._upstream(self.command, self.path, headers, body)
        self._send(status, hs, b)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _handle


def main():
    global args
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--mail", default="ada@outlook.rig.test")
    args = ap.parse_args()
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Front)
    with open(args.port_file + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.rename(args.port_file + ".tmp", args.port_file)
    srv.serve_forever()


main()
