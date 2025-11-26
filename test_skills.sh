#!/bin/bash
# Test all Mimo MCP skills
# Usage: ./test_skills.sh

set -e
cd "$(dirname "$0")"
source .env 2>/dev/null || true

echo "=== Mimo MCP Skills Test ==="
echo ""

test_tool() {
    local name="$1"
    local args="$2"
    echo -n "Testing $name... "
    
    result=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$name" "$args" | timeout 60 python3 mimo-mcp-stdio.py 2>/dev/null | tail -1)
    
    if echo "$result" | grep -q '"result"'; then
        echo "✅ OK"
        return 0
    elif echo "$result" | grep -q '"error"'; then
        error=$(echo "$result" | grep -o '"message":"[^"]*"' | head -1)
        echo "❌ FAIL: $error"
        return 1
    else
        echo "❌ TIMEOUT/NO RESPONSE"
        return 1
    fi
}

echo "--- Internal Tools ---"
test_tool "ask_mimo" '{"query":"test"}'
test_tool "mimo_store_memory" '{"content":"test from script","category":"fact"}'

echo ""
echo "--- Fetch Skills ---"
test_tool "fetch_fetch_txt" '{"url":"https://example.com"}'
test_tool "fetch_fetch_json" '{"url":"https://httpbin.org/json"}'

echo ""
echo "--- Sequential Thinking ---"
test_tool "sequential_thinking_sequentialthinking" '{"thought":"test","thoughtNumber":1,"totalThoughts":1,"nextThoughtNeeded":false}'

echo ""
echo "--- Exa Search (requires EXA_API_KEY) ---"
if [ -n "$EXA_API_KEY" ]; then
    test_tool "exa_search_web_search_exa" '{"query":"test"}'
else
    echo "⏭️  SKIPPED (no EXA_API_KEY)"
fi

echo ""
echo "--- Desktop Commander ---"
test_tool "desktop_commander_list_directory" '{"path":"/workspace"}'
test_tool "desktop_commander_read_file" '{"path":"/workspace/README.md"}'

echo ""
echo "--- Puppeteer (requires Docker-in-Docker) ---"
test_tool "puppeteer_puppeteer_navigate" '{"url":"https://example.com"}'

echo ""
echo "=== Test Complete ==="
