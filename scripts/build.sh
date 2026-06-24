#!/bin/bash
# Build the Orchestra package (core + daemon + CLI + MCP bridge).
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift build "$@"
