#!/usr/bin/env python3
"""
debug_stream.py - VS Code MCP Client Simulator

This script simulates how VS Code/GitHub Copilot interacts with the MCP server.
It keeps a persistent SSH connection open and sends multiple requests,
verifying that each response returns without hanging.

Usage:
    python debug_stream.py [--host HOST] [--wrapper PATH]

Example:
    python debug_stream.py --host root@<YOUR_VPS_IP>
"""

import subprocess
import sys
import json
import time
import argparse
import select

def log(msg, level="INFO"):
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] [{level}] {msg}", file=sys.stderr, flush=True)

def send_request(proc, request_dict, timeout=30):
    """Send a JSON-RPC request and wait for response."""
    request_json = json.dumps(request_dict) + "\n"
    request_id = request_dict.get("id")
    
    log(f"→ Sending: {request_dict.get('method', 'notification')} (id={request_id})")
    
    start_time = time.time()
    proc.stdin.write(request_json)
    proc.stdin.flush()
    
    # For notifications (no id), don't wait for response
    if request_id is None:
        log(f"  (notification - no response expected)")
        return None
    
    # Wait for response with timeout
    response_line = None
    while (time.time() - start_time) < timeout:
        # Use select to check if data is available
        readable, _, _ = select.select([proc.stdout], [], [], 0.1)
        if readable:
            line = proc.stdout.readline()
            if line:
                try:
                    response = json.loads(line)
                    if response.get("id") == request_id:
                        elapsed = time.time() - start_time
                        log(f"← Response received in {elapsed:.3f}s")
                        return response
                except json.JSONDecodeError:
                    log(f"  (skipping non-JSON: {line[:50]}...)")
        
        # Check if process died
        if proc.poll() is not None:
            log(f"Process exited with code {proc.returncode}", "ERROR")
            return None
    
    log(f"Timeout waiting for response to id={request_id}", "ERROR")
    return None

def main():
    parser = argparse.ArgumentParser(description="VS Code MCP Client Simulator")
    parser.add_argument("--host", default="root@localhost", help="SSH host (e.g., root@your-vps-ip)")
    parser.add_argument("--wrapper", default="/usr/local/bin/mimo-mcp-stdio", help="Path to wrapper script")
    args = parser.parse_args()
    
    log("=" * 60)
    log("MIMO MCP Persistent Connection Test")
    log("=" * 60)
    log(f"Host: {args.host}")
    log(f"Wrapper: {args.wrapper}")
    log("")
    
    # Start SSH connection with MCP server
    cmd = [
        "ssh", "-T",
        "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        args.host,
        args.wrapper
    ]
    
    log(f"Starting: {' '.join(cmd)}")
    
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
        text=True
    )
    
    log("")
    all_passed = True
    
    # Test 1: Initialize
    log("-" * 40)
    log("TEST 1: Initialize Request")
    log("-" * 40)
    response = send_request(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize"
    })
    if response and "result" in response:
        server_info = response["result"].get("serverInfo", {})
        log(f"✅ PASS - Server: {server_info.get('name')} v{server_info.get('version')}")
    else:
        log("❌ FAIL - No valid response", "ERROR")
        all_passed = False
    
    # Test 2: Initialized notification (no response expected)
    log("")
    log("-" * 40)
    log("TEST 2: Initialized Notification")
    log("-" * 40)
    send_request(proc, {
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    })
    log("✅ PASS - Notification sent (no response expected)")
    time.sleep(0.5)  # Give server time to process
    
    # Test 3: Tools list
    log("")
    log("-" * 40)
    log("TEST 3: Tools List Request")
    log("-" * 40)
    response = send_request(proc, {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list"
    })
    if response and "result" in response:
        tools = response["result"].get("tools", [])
        log(f"✅ PASS - {len(tools)} tools available")
        log(f"   Sample tools: {[t['name'] for t in tools[:5]]}...")
    else:
        log("❌ FAIL - No valid response", "ERROR")
        all_passed = False
    
    # Test 4: Tool call (ask_mimo)
    log("")
    log("-" * 40)
    log("TEST 4: Tool Call - ask_mimo")
    log("-" * 40)
    response = send_request(proc, {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "ask_mimo",
            "arguments": {"query": "What is the capital of France?"}
        }
    }, timeout=30)  # LLM calls may take longer
    if response and "result" in response:
        content = response["result"].get("content", [])
        if content:
            text = content[0].get("text", "")
            log(f"✅ PASS - Got response: {text[:100]}...")
        else:
            log("✅ PASS - Got empty content (may be expected)")
    elif response and "error" in response:
        log(f"⚠️  ERROR response: {response['error'].get('message')}", "WARN")
        all_passed = False
    else:
        log("❌ FAIL - No valid response", "ERROR")
        all_passed = False
    
    # Test 5: Another request to verify connection is still alive
    log("")
    log("-" * 40)
    log("TEST 5: Connection Still Alive Check")
    log("-" * 40)
    response = send_request(proc, {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/list"
    })
    if response and "result" in response:
        log("✅ PASS - Connection is still alive after multiple requests")
    else:
        log("❌ FAIL - Connection may have died", "ERROR")
        all_passed = False
    
    # Cleanup
    log("")
    log("=" * 60)
    log("SUMMARY")
    log("=" * 60)
    
    if all_passed:
        log("✅ ALL TESTS PASSED - Buffering is fixed!")
        log("")
        log("The MCP server correctly handles persistent connections.")
        log("VS Code should now be able to communicate without hanging.")
    else:
        log("❌ SOME TESTS FAILED", "ERROR")
        log("")
        log("Check the VPS logs: ssh root@<YOUR_VPS_IP> cat /tmp/mcp-wrapper.log")
    
    # Close connection gracefully
    log("")
    log("Closing connection...")
    try:
        proc.stdin.close()
        proc.terminate()
        proc.wait(timeout=2)
    except:
        proc.kill()
    log("Done.")
    
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
