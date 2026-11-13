#!/usr/bin/env python3
"""Loopback JSON-RPC proxy that can answer HTTP 429 on demand, for the rate limit rehearsal.

    AMOY_RPC_URL=... python3 scripts/demo/rpc-fault-proxy.py --listen 127.0.0.1:8545

The proxy forwards every POST to the upstream RPC (read from an environment variable, never from
the command line) and returns the upstream answer. While the limit mode is on it answers 429 with
`Retry-After: 5` and a JSON-RPC error (code -32005, "rate limit exceeded") that echoes the
request id, which is what a rate limited provider does.

Control, from loopback only:
    POST /__fault/on       start answering 429
    POST /__fault/off      stop answering 429 (also ends a scheduled window)
    GET  /__fault/status   JSON with the current mode

Scheduled window: --limit-after SECONDS --limit-for SECONDS turns the limit on that long after
the start and off again after the window.

Safety rules:
    - it refuses to listen on anything but a loopback address (exit 2);
    - the upstream URL is read from the environment variable named by --upstream-env
      (default AMOY_RPC_URL) and is never printed or logged; it must be https, except for a
      loopback upstream, which tests use;
    - a log line holds the UTC time, the JSON-RPC method (or "batch"), the decision and the
      status. Bodies, headers and the upstream URL are never logged;
    - bodies above 1 MB are refused with 413.

Python 3 standard library only. Exit codes: 0 stopped by signal, 2 bad usage or environment.
"""

import argparse
import ipaddress
import json
import os
import re
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 1024 * 1024
UPSTREAM_TIMEOUT = 20
RETRY_AFTER = "5"
METHOD_RE = re.compile(r"^[A-Za-z0-9_]{1,64}$")
LOOPBACK_CLIENTS = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def die(message, code=2):
    print("rpc-fault-proxy: " + message, file=sys.stderr)
    sys.exit(code)


def is_loopback_host(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def parse_listen(value):
    host, sep, port = value.rpartition(":")
    if not sep or not host or not port.isdigit() or int(port) > 65535:
        die("--listen must look like HOST:PORT, for example 127.0.0.1:8545")
    host = host.strip("[]")
    if not is_loopback_host(host):
        die("refusing to listen on a non loopback address; use 127.0.0.1, ::1 or localhost")
    return host, int(port)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class FaultState:
    """Thread safe limit mode: a manual switch plus an optional scheduled window."""

    def __init__(self, after, duration):
        self.lock = threading.Lock()
        self.manual = False
        self.started = time.monotonic()
        self.after = after
        self.duration = duration
        self.schedule_cancelled = False

    def scheduled_active(self):
        if self.after is None or self.duration is None or self.schedule_cancelled:
            return False
        elapsed = time.monotonic() - self.started
        return self.after <= elapsed < self.after + self.duration

    def limited(self):
        with self.lock:
            return self.manual or self.scheduled_active()

    def set_manual(self, on):
        with self.lock:
            self.manual = on
            if not on:
                self.schedule_cancelled = True

    def snapshot(self):
        with self.lock:
            return {
                "limited": self.manual or self.scheduled_active(),
                "manual": self.manual,
                "scheduled": self.after is not None and not self.schedule_cancelled,
            }


def limited_body(payload):
    def one(request_id):
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32005, "message": "rate limit exceeded"}}

    if isinstance(payload, list):
        return [one(item.get("id") if isinstance(item, dict) else None) for item in payload]
    return one(payload.get("id") if isinstance(payload, dict) else None)


def method_label(payload):
    if isinstance(payload, list):
        return "batch"
    if isinstance(payload, dict):
        method = payload.get("method")
        if isinstance(method, str) and METHOD_RE.match(method):
            return method
    return "unknown"


def make_handler(state, upstream):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        server_version = "latifi-fault-proxy"
        sys_version = ""

        def log_message(self, fmt, *args):  # the default access log would print the request line
            pass

        def log_line(self, method, decision, status):
            print("%s %s %s %s" % (now_iso(), method, decision, status), flush=True)

        def send_json(self, status, payload, extra=None):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in (extra or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def from_loopback(self):
            return self.client_address[0] in LOOPBACK_CLIENTS

        def do_GET(self):
            if self.path == "/__fault/status":
                if not self.from_loopback():
                    return self.send_json(403, {"error": "loopback only"})
                return self.send_json(200, state.snapshot())
            self.send_json(405, {"error": "POST a JSON-RPC request"})

        def do_POST(self):
            if self.path in ("/__fault/on", "/__fault/off"):
                if not self.from_loopback():
                    return self.send_json(403, {"error": "loopback only"})
                state.set_manual(self.path.endswith("/on"))
                self.log_line("control", self.path.rsplit("/", 1)[1], 200)
                return self.send_json(200, state.snapshot())

            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                self.log_line("unknown", "refused", 411)
                return self.send_json(411, {"error": "Content-Length required"})
            if length < 0 or length > MAX_BODY:
                self.log_line("unknown", "refused", 413)
                return self.send_json(413, {"error": "body too large"})
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = None
            label = method_label(payload)

            if state.limited():
                self.log_line(label, "limited", 429)
                return self.send_json(429, limited_body(payload), {"Retry-After": RETRY_AFTER})

            request = urllib.request.Request(upstream, data=raw, method="POST", headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT) as answer:
                    status, body = answer.status, answer.read()
            except urllib.error.HTTPError as err:
                status, body = err.code, err.read()
            except Exception:  # never echo the exception: it can repeat the upstream URL
                self.log_line(label, "forward", 502)
                return self.send_json(502, {"error": "upstream unreachable"})
            self.log_line(label, "forward", status)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def read_upstream(env_name):
    value = os.environ.get(env_name, "")
    if not value:
        die("the environment variable %s is not set" % env_name)
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme == "https" and parsed.hostname:
        return value
    if parsed.scheme == "http" and parsed.hostname and is_loopback_host(parsed.hostname):
        return value
    die("the upstream in %s must be an https URL (http is allowed for a loopback upstream only)" % env_name)


def main():
    parser = argparse.ArgumentParser(description="Loopback RPC proxy with an on demand HTTP 429 mode.")
    parser.add_argument("--listen", default="127.0.0.1:8545", help="loopback HOST:PORT (default 127.0.0.1:8545)")
    parser.add_argument("--upstream-env", default="AMOY_RPC_URL", help="environment variable that holds the upstream URL")
    parser.add_argument("--limit-after", type=float, default=None, help="seconds after the start when the limit turns on")
    parser.add_argument("--limit-for", type=float, default=None, help="seconds the limit stays on")
    args = parser.parse_args()

    if (args.limit_after is None) != (args.limit_for is None):
        die("--limit-after and --limit-for go together")
    if args.limit_after is not None and (args.limit_after < 0 or args.limit_for <= 0):
        die("--limit-after must be 0 or more and --limit-for above 0")
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", args.upstream_env):
        die("--upstream-env must be an environment variable name")

    host, port = parse_listen(args.listen)
    upstream = read_upstream(args.upstream_env)
    state = FaultState(args.limit_after, args.limit_for)

    class Server(ThreadingHTTPServer):
        daemon_threads = True
        address_family = socket.AF_INET6 if ":" in host else socket.AF_INET

    server = Server((host, port), make_handler(state, upstream))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print("rpc-fault-proxy: listening on %s:%d (upstream from %s, never printed)" % (host, server.server_address[1], args.upstream_env), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
