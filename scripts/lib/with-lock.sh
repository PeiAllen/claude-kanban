#!/bin/bash
# Run a command under a named machine-wide mutex. Thin shell front-end to with-lock.py.
#
#   scripts/lib/with-lock.sh build -- swift build --build-tests
#   scripts/lib/with-lock.sh ship  -- git merge --no-edit some-branch
#
# Wrap a build COMMAND, never a whole script that backgrounds a daemon — see with-lock.py.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/with-lock.py" "$@"
