#!/usr/bin/env python3
"""Small Unix-socket server fixture for Codex launcher lifecycle tests."""

import os
import signal
import socket
import sys
import time


socket_path, ready_path, term_path, done_path, shutdown_delay = sys.argv[1:]
shutting_down = False


def mark(path):
    with open(path, "w", encoding="utf-8") as marker:
        marker.write("1\n")


def shutdown(_signum, _frame):
    global shutting_down
    if shutting_down:
        return
    shutting_down = True
    mark(term_path)
    time.sleep(float(shutdown_delay))
    mark(done_path)
    os._exit(0)


for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, shutdown)

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(socket_path)
listener.listen(1)
mark(ready_path)

while True:
    time.sleep(1)
