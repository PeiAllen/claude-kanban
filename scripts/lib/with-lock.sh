#!/bin/bash
# Run a command under a named machine-wide mutex. Thin shell front-end to with-lock.py.
#
#   scripts/lib/with-lock.sh build -- swift build --build-tests   # throttle: fails OPEN
#   scripts/lib/with-lock.sh --strict ship -- git merge …         # shared state: fails CLOSED
#
# Wrap a build COMMAND, not a whole script that backgrounds a daemon — see with-lock.py.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/with-lock.py" "$@"
