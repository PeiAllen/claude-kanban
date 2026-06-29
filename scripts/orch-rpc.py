#!/usr/bin/env python3
"""Minimal JSON-RPC client for an Orchestra daemon over its UDS socket.

Used by scripts/orch-test.sh to drive an *isolated* test daemon. Reads the socket path from
$ORCH_SOCK. Usage: ORCH_SOCK=<path> orch-rpc.py <method> '<json-params>'
Prints the result (or error) as JSON; exit 1 on an RPC error.
"""
import socket, json, sys, os

sock_path = os.environ.get("ORCH_SOCK")
if not sock_path:
    sys.exit("orch-rpc: set ORCH_SOCK to the daemon socket path")
method = sys.argv[1] if len(sys.argv) > 1 else sys.exit("orch-rpc: <method> required")
params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else None

req = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params, "source": "cli"}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall((json.dumps(req) + "\n").encode())
s.settimeout(10)
buf = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
    for line in buf.split(b"\n"):
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == 1:                       # our response (skip event notifications)
            err = msg.get("error")
            print(json.dumps(err or msg.get("result"), indent=2))
            sys.exit(1 if err else 0)
sys.exit("orch-rpc: connection closed with no response")
