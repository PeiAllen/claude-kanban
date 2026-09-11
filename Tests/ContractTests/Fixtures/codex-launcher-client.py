#!/usr/bin/env python3
"""Client fixture that either exits immediately or holds the launcher open."""

import os
import sys
import time


ready_path, entered_path, stop_path, mode = sys.argv[1:]


def mark(path):
    with open(path, "w", encoding="utf-8") as marker:
        marker.write("1\n")


while not os.path.exists(ready_path):
    time.sleep(0.01)

mark(entered_path)
if mode == "exit":
    sys.exit(0)

while not os.path.exists(stop_path):
    time.sleep(0.01)
