#!/bin/bash
# Build the Orchestra package (core + daemon + CLI + MCP bridge).
#
# Runs under the machine-wide BUILD MUTEX. Measured: one cold build takes 165s, but THREE
# concurrent ones take 520s EACH — build concurrency is super-linear loss, so serializing is
# faster in total and keeps the app/daemon responsive. If another card is building you will
# see "[build-lock] waiting for slot…" on stderr; the wait is bounded and never fails the
# build. See notes/designs/build-contention.md.
set -euo pipefail
cd "$(dirname "$0")/.."
exec scripts/lib/with-lock.sh build -- swift build "$@"
