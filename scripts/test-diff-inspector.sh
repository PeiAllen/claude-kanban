#!/bin/bash
# Private native-UI checks. Does not install Orchestra or contact its daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/lib/test-diff-inspector.py "$@"
