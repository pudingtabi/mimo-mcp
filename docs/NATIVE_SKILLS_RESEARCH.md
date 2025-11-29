# Mimo Native Skills Spec
## Zero-Dependency Built-in Skills for Elixir/OTP

**Version:** 2.0
**Date:** 2025-11-26
**Status:** Research Required

---

## Design Principles

1. **Zero external dependencies** - Only Elixir/OTP stdlib
2. **No API keys required** - Self-contained functionality
3. **Pure Elixir** - No NIFs, no Ports to external programs (except for browser)
4. **Single process** - Skills run in Mimo's BEAM VM, not subprocesses

---

## Skills to Implement

### 1. HTTP/Fetch Skills

**Tools:**
- `fetch_text` - Fetch URL, return plain text
- `fetch_html` - Fetch URL, return raw HTML
- `fetch_json` - Fetch URL, parse JSON
- `fetch_markdown` - Fetch URL, convert HTML to Markdown

**Elixir/OTP Requirements:**
| Requirement | OTP Module | Notes |
|-------------|------------|-------|
| HTTP client | `:httpc` | Built into OTP (inets) |
| SSL/TLS | `:ssl` | Built into OTP |
| URI parsing | `URI` | Elixir stdlib |
| JSON parsing | Need to evaluate | Jason already in deps, or write simple parser |

**Research Topics:**
- [ ] `:httpc` usage for GET/POST requests
- [ ] SSL certificate handling with `:ssl`
- [ ] Following redirects manually
- [ ] HTML to plain text extraction (strip tags with regex/parser)
- [ ] HTML to Markdown conversion algorithm
- [ ] Timeout and error handling
- [ ] User-Agent and headers

**Spec:**
```elixir
# Input
%{
  "url" => "https://example.com",
  "headers" => %{"User-Agent" => "Mimo/1.0"},  # optional
  "timeout" => 30000  # optional, ms
}

# Output
{:ok, %{
  "content" => "...",
  "status" => 200,
  "headers" => %{...},
  "content_type" => "text/html"
}}
```

---

### 2. File Skills

**Tools:**
- `read_file` - Read file contents
- `write_file` - Write/overwrite file
- `append_file` - Append to file
- `list_directory` - List directory contents with metadata
- `create_directory` - Create directory (recursive)
- `move_file` - Move/rename file or directory
- `delete_file` - Delete file
- `delete_directory` - Delete directory (recursive)
- `file_info` - Get file metadata (size, modified, type)
- `file_exists` - Check if path exists
- `search_files` - Find files by pattern

**Elixir/OTP Requirements:**
| Requirement | OTP Module | Notes |
|-------------|------------|-------|
| File operations | `File` | Elixir stdlib |
| Path manipulation | `Path` | Elixir stdlib |
| File info | `File.stat/1` | Returns `%File.Stat{}` |
| Directory walk | `:filelib.wildcard/1` | OTP |
| Stream large files | `File.stream!/1` | Elixir stdlib |

**Research Topics:**
- [ ] Path traversal security (prevent `../../etc/passwd`)
- [ ] Allowed directories whitelist
- [ ] Large file handling with streams
- [ ] Binary vs text detection
- [ ] Encoding detection (UTF-8, etc.)
- [ ] Atomic writes (write to temp, then rename)
- [ ] File permissions on create

**Spec:**
```elixir
# read_file input
%{"path" => "/workspace/file.txt", "encoding" => "utf-8"}

# list_directory input
%{"path" => "/workspace", "recursive" => false, "pattern" => "*.ex"}

# Security: paths must be within allowed_directories config
```

---

### 3. Text/Edit Skills

**Tools:**
- `edit_file` - Find and replace in file
- `search_text` - Search for pattern in text/file
- `diff_text` - Compare two texts

**Elixir/OTP Requirements:**
| Requirement | OTP Module | Notes |
|-------------|------------|-------|
| String ops | `String` | Elixir stdlib |
| Regex | `Regex` | Elixir stdlib |
| Binary pattern | `:binary` | OTP |

**Research Topics:**
- [ ] Exact match vs regex replacement
- [ ] Multi-occurrence handling
- [ ] Context-aware replacement (ensure uniqueness)
- [ ] Line number tracking
- [ ] Diff algorithm (simple line-based)

**Spec:**
```elixir
# edit_file input
%{
  "path" => "/workspace/file.ex",
  "old_text" => "def foo do",
  "new_text" => "def bar do",
  "occurrence" => 1  # which occurrence, or "all"
}

# Output
{:ok, %{"changed" => true, "occurrences_replaced" => 1}}
```

---

### 4. Process/Terminal Skills

**Tools:**
- `exec_command` - Execute shell command, return output
- `spawn_process` - Start long-running process
- `kill_process` - Terminate process
- `list_processes` - List Mimo-spawned processes

**Elixir/OTP Requirements:**
| Requirement | OTP Module | Notes |
|-------------|------------|-------|
| Run command | `System.cmd/3` | Simple execution |
| Port | `Port` | For interactive processes |
| Process registry | `Registry` | Track spawned processes |

**Research Topics:**
- [ ] Command whitelist (security)
- [ ] Argument sanitization (no injection)
- [ ] Timeout enforcement
- [ ] Output size limits
- [ ] Environment variable handling
- [ ] Working directory
- [ ] Interactive stdin/stdout with Port
- [ ] Process supervision and cleanup

**Security Critical:**
```elixir
# MUST implement:
@allowed_commands ["ls", "cat", "grep", "find", "echo", "date", "whoami"]
# NO: rm, curl, wget, bash, sh, python, node (unless whitelisted)
```

**Spec:**
```elixir
# exec_command input
%{
  "command" => "ls",
  "args" => ["-la", "/workspace"],
  "timeout" => 30000,
  "cwd" => "/workspace"
}

# Output
{:ok, %{"stdout" => "...", "stderr" => "", "exit_code" => 0}}
```

---

### 5. Reasoning Skills

**Tools:**
- `think` - Record a thought step
- `plan` - Create task breakdown
- `reflect` - Analyze previous actions

**Elixir/OTP Requirements:**
| Requirement | OTP Module | Notes |
|-------------|------------|-------|
| Data structures | `Map`, `List` | Elixir stdlib |
| Timestamps | `DateTime` | Elixir stdlib |
| State | Agent/GenServer | If persistence needed |

**Research Topics:**
- [ ] Thought chain data structure
- [ ] Integration with Procedural Store
- [ ] Plan → subtasks decomposition
- [ ] Progress tracking

**Spec:**
```elixir
# think input
%{
  "thought" => "I need to first read the file, then parse it",
  "step" => 1,
  "total_steps" => 3
}

# plan input  
%{
  "goal" => "Refactor the authentication module",
  "context" => "Current code uses sessions, need to add JWT"
}

# Output
{:ok, %{
  "plan_id" => "uuid",
  "steps" => [
    %{"step" => 1, "action" => "Read current auth module", "status" => "pending"},
    %{"step" => 2, "action" => "Add JWT dependency", "status" => "pending"},
    ...
  ]
}}
```

---

### 6. Browser Skills (External - Keep Puppeteer)

**Reason:** Browser automation requires Chrome/Chromium binary. Cannot be pure Elixir.

**Options:**
1. Keep external MCP puppeteer (current)
2. Use Chrome DevTools Protocol (CDP) directly from Elixir via WebSocket
3. Use screenshot API service

**Research Topics (if doing CDP):**
- [ ] WebSocket client in OTP (`:gun` or `mint`)
- [ ] CDP protocol messages
- [ ] Managing headless Chrome process
- [ ] Screenshot encoding (base64)

---

### 7. Web Search Skills (Requires API)

**Note:** Web search inherently requires external API (Google, Bing, Exa, etc.)

**Options:**
1. Keep Exa API integration (current) - requires EXA_API_KEY
2. Add DuckDuckGo scraping (no API key, but fragile)
3. Add SearXNG self-hosted option

**Research Topics:**
- [ ] DuckDuckGo HTML scraping feasibility
- [ ] SearXNG API format
- [ ] Caching search results

---

## Skill Behaviour Interface

```elixir
defmodule Mimo.Skills.Native.Behaviour do
  @moduledoc "All native skills must implement this behaviour"
  
  # Skill metadata
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback category() :: :web | :file | :terminal | :reasoning | :browser
  
  # JSON Schema for MCP compatibility
  @callback input_schema() :: map()
  
  # Execution
  @callback execute(args :: map(), context :: map()) :: 
    {:ok, any()} | {:error, String.t()}
  
  # Optional: validation before execute
  @callback validate(args :: map()) :: :ok | {:error, String.t()}
end
```

---

## File Structure

```
lib/mimo/skills/
├── native/
│   ├── behaviour.ex          # Behaviour definition
│   ├── registry.ex           # Native skill registry
│   │
│   ├── web/
│   │   ├── fetch.ex          # HTTP fetching
│   │   └── html_parser.ex    # HTML → text/markdown
│   │
│   ├── file/
│   │   ├── operations.ex     # CRUD operations
│   │   ├── search.ex         # File search
│   │   └── security.ex       # Path validation
│   │
│   ├── text/
│   │   ├── edit.ex           # Find/replace
│   │   └── diff.ex           # Text comparison
│   │
│   ├── terminal/
│   │   ├── executor.ex       # Command execution
│   │   └── whitelist.ex      # Allowed commands
│   │
│   └── reasoning/
│       ├── think.ex          # Thought recording
│       └── plan.ex           # Task planning
```

---

## OTP Modules Reference

| Category | Module | Purpose |
|----------|--------|---------|
| HTTP | `:httpc` | HTTP client (inets app) |
| SSL | `:ssl` | TLS connections |
| Files | `File`, `Path` | File operations |
| Files | `:filelib` | Wildcard, fold_files |
| Process | `Port` | External process I/O |
| Process | `System` | System commands |
| Binary | `:binary` | Binary pattern matching |
| Crypto | `:crypto` | Hashing, random |
| JSON | `:json` (OTP 27+) | Native JSON (or use Jason) |
| Timer | `:timer` | Timeouts |
| URI | `URI` | URL parsing |

---

## Security Checklist

- [ ] Path traversal prevention (all file operations)
- [ ] Command injection prevention (terminal skills)
- [ ] Timeout on all external operations
- [ ] Output size limits
- [ ] Allowed directories config
- [ ] Allowed commands whitelist
- [ ] Rate limiting per skill
- [ ] Audit logging

---

## Research Tasks

### Priority 1: HTTP/Fetch
1. Research `:httpc` for HTTP GET/POST with headers
2. Research HTML tag stripping algorithm
3. Research HTML to Markdown conversion rules

### Priority 2: File Operations
4. Research path canonicalization for security
5. Research streaming large files
6. Research recursive directory operations

### Priority 3: Terminal
7. Research `System.cmd` vs `Port` tradeoffs
8. Research command sandboxing approaches
9. Research PTY for interactive commands

### Priority 4: Reasoning
10. Research thought chain patterns
11. Research task decomposition algorithms

---

## Success Criteria

| Metric | Target |
|--------|--------|
| External dependencies | 0 (pure OTP) |
| API keys required | 0 (except optional search) |
| Startup time | <10ms per skill |
| Memory overhead | 0 (same BEAM process) |
| Test coverage | >90% |

---

## Not In Scope

- Browser automation (keep external)
- Video/audio processing
- Machine learning inference
- Database connections (use existing Mimo stores)
- Email sending
- SMS/notifications
