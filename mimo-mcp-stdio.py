#!/usr/bin/env python3
"""
MCP STDIO Bridge - Buffer-Free Edition v4
Fixed line wrapping issues, proper input buffering.
"""
import subprocess
import sys
import os
import select
import fcntl
import time

os.environ['PYTHONUNBUFFERED'] = '1'
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)

DEBUG = True
LOG_FILE = "/tmp/mcp-wrapper.log"

def log(msg):
    if DEBUG:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{os.getpid()}] {time.strftime('%H:%M:%S')} {msg}\n")
            f.flush()

def set_nonblocking(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

def main():
    log("=== SESSION START v4 ===")
    
    cmd = [
        "docker", "exec", "-i",
        "-e", "MIX_ENV=prod",
        "mimo-mcp",
        "mix", "run", "--no-compile", "--no-halt",
        "-e", "Mimo.McpCli.run()"
    ]
    
    log(f"Starting: {' '.join(cmd)}")
    
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0
    )
    
    set_nonblocking(proc.stdout.fileno())
    set_nonblocking(proc.stderr.fileno())
    set_nonblocking(sys.stdin.fileno())
    
    stdin_fd = sys.stdin.fileno()
    stdout_fd = proc.stdout.fileno()
    stderr_fd = proc.stderr.fileno()
    
    stdin_open = True
    output_buffer = b""
    input_buffer = b""
    
    try:
        while True:
            fds_to_watch = [stdout_fd, stderr_fd]
            if stdin_open:
                fds_to_watch.append(stdin_fd)
            
            readable, _, _ = select.select(fds_to_watch, [], [], 1.0)
            
            if proc.poll() is not None:
                try:
                    remaining = proc.stdout.read()
                    if remaining:
                        output_buffer += remaining
                except:
                    pass
                if output_buffer:
                    process_output(output_buffer)
                log(f"Process exited: {proc.returncode}")
                break
            
            for fd in readable:
                if fd == stdin_fd:
                    try:
                        data = os.read(stdin_fd, 65536)
                        if not data:
                            log("EOF from stdin")
                            stdin_open = False
                            proc.stdin.close()
                        else:
                            input_buffer += data
                            # Process complete lines from input
                            while b'\n' in input_buffer:
                                line, input_buffer = input_buffer.split(b'\n', 1)
                                if line.strip():
                                    log(f"[IN] {line.decode('utf-8', errors='replace').rstrip()}")
                                    proc.stdin.write(line + b'\n')
                                    proc.stdin.flush()
                    except BlockingIOError:
                        pass
                    except OSError:
                        stdin_open = False
                
                elif fd == stdout_fd:
                    try:
                        data = proc.stdout.read(65536)
                        if data:
                            log(f"[RAW_OUT] {len(data)} bytes")
                            output_buffer += data
                            while b'\n' in output_buffer:
                                line, output_buffer = output_buffer.split(b'\n', 1)
                                process_line(line.decode('utf-8', errors='replace'))
                    except BlockingIOError:
                        pass
                
                elif fd == stderr_fd:
                    try:
                        data = proc.stderr.read(65536)
                        if data:
                            log(f"[ERR] {data.decode('utf-8', errors='replace')}")
                    except BlockingIOError:
                        pass
                        
    except KeyboardInterrupt:
        log("Interrupted")
    except Exception as e:
        log(f"Error: {e}")
        import traceback
        log(traceback.format_exc())
    finally:
        try:
            proc.terminate()
        except:
            pass
        log("=== SESSION END ===")

def process_line(line):
    line = line.strip()
    if not line:
        return
    # Only pass valid JSON-RPC messages (must start with {"jsonrpc" or {"id" or {"result" or {"error")
    if line.startswith('{"jsonrpc') or line.startswith('{"id') or line.startswith('{"result') or line.startswith('{"error'):
        log(f"[OUT] {line}")
        print(line, flush=True)
    elif line.startswith('{'):
        # Elixir tuple like {:ip, or {:port, - skip these
        log(f"[SKIP_ELIXIR] {line}")
    else:
        log(f"[SKIP] {line}")

def process_output(data):
    text = data.decode('utf-8', errors='replace')
    for line in text.split('\n'):
        process_line(line)

if __name__ == "__main__":
    main()
