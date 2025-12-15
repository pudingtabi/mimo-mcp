#!/bin/bash
# MCP stdio smoke test for the current in-repo Mimo MCP server.
# Usage: ./test_skills.sh

set -euo pipefail
cd "$(dirname "$0")"

# Keep output deterministic and avoid Elixir's latin1 warnings.
export LC_ALL="C.UTF-8"
export LANG="C.UTF-8"
export ELIXIR_ERL_OPTIONS="+fnu"

python3 scripts/mcp_smoke_test.py
