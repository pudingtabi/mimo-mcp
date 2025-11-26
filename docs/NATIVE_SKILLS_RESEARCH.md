# Mimo Built-in Skills Research Spec
## Goal: Replace External MCP Skills with Native Elixir Implementation

**Version:** 1.0
**Date:** 2025-11-26
**Status:** Research Phase

---

## Executive Summary

Replace slow, fragile external MCP skills (npx subprocesses) with fast, native Elixir implementations. This will make Mimo self-contained, faster, and more reliable.

---

## Current Architecture Problems

| Problem | Impact | Root Cause |
|---------|--------|------------|
| Slow startup | 5-30s per skill | npx downloads packages |
| Process overhead | Memory/CPU waste | Spawns Node.js per skill |
| Fragile IPC | Timeouts, crashes | Line-mode tuples, JSON over stdio |
| External deps | Version conflicts | npm packages we don't control |
| Complex debugging | Hard to trace issues | Cross-process boundaries |

---

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MIMO NATIVE SKILLS                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Web       │  │   File      │  │  Browser    │             │
│  │  Skills     │  │  Skills     │  │  Skills     │             │
│  ├─────────────┤  ├─────────────┤  ├─────────────┤             │
│  │ • fetch     │  │ • read_file │  │ • navigate  │             │
│  │ • exa_search│  │ • write_file│  │ • screenshot│             │
│  │ • scrape    │  │ • list_dir  │  │ • click     │             │
│  │             │  │ • edit_file │  │ • fill      │             │
│  └─────────────┘  │ • search    │  └─────────────┘             │
│                   └─────────────┘                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │  Terminal   │  │  Reasoning  │  │   Code      │             │
│  │  Skills     │  │  Skills     │  │  Skills     │             │
│  ├─────────────┤  ├─────────────┤  ├─────────────┤             │
│  │ • exec_cmd  │  │ • think     │  │ • run_python│             │
│  │ • spawn_proc│  │ • plan      │  │ • run_node  │             │
│  │ • interact  │  │ • reflect   │  │ • run_shell │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Research Areas

### 1. Web Skills (Priority: HIGH)

#### 1.1 Fetch Skill
**Current:** `@tokenizin/mcp-npx-fetch` (Node.js)
**Replacement:** Native HTTPoison/Req

```elixir
# Research needed:
- [ ] HTTPoison vs Req vs Finch - which is best?
- [ ] HTML to Markdown conversion (Floki + custom?)
- [ ] HTML to plain text extraction
- [ ] Handling redirects, cookies, headers
- [ ] Rate limiting per domain
- [ ] Timeout handling
- [ ] SSL/TLS configuration
```

**Estimated effort:** 2-4 hours
**Dependencies:** HTTPoison (already in deps), Floki (HTML parsing)

#### 1.2 Exa Search Skill
**Current:** `exa-mcp-server` (Node.js)
**Replacement:** Direct Exa API calls

```elixir
# Research needed:
- [ ] Exa API documentation review
- [ ] API endpoints: /search, /contents, /find-similar
- [ ] Response parsing and formatting
- [ ] Error handling and rate limits
- [ ] Caching strategy for repeated queries
```

**Estimated effort:** 1-2 hours
**Dependencies:** HTTPoison, Jason

#### 1.3 Web Scraping Skill (NEW)
**Current:** None
**Proposal:** Built-in scraper

```elixir
# Research needed:
- [ ] Floki for HTML parsing
- [ ] CSS selector support
- [ ] XPath support (optional)
- [ ] JavaScript-rendered content (needs browser?)
- [ ] Robots.txt compliance
- [ ] User-agent rotation
```

**Estimated effort:** 4-6 hours
**Dependencies:** Floki, HTTPoison

---

### 2. File Skills (Priority: HIGH)

#### 2.1 File Operations
**Current:** `@wonderwhy-er/desktop-commander` (Node.js)
**Replacement:** Native Elixir File module

```elixir
# Research needed:
- [ ] File.read/write/stream for large files
- [ ] Path traversal security (prevent escaping allowed dirs)
- [ ] Allowed directories configuration
- [ ] File watching (FileSystem library?)
- [ ] Atomic writes (temp file + rename)
- [ ] Encoding detection and handling
- [ ] Binary vs text file detection
```

**Tools to implement:**
| Tool | Elixir Implementation |
|------|----------------------|
| read_file | `File.read/1` + streaming for large files |
| write_file | `File.write/2` with atomic option |
| list_directory | `File.ls/1` + `File.stat/1` |
| create_directory | `File.mkdir_p/1` |
| move_file | `File.rename/2` |
| delete_file | `File.rm/1` |
| get_file_info | `File.stat/1` |
| search_files | Walk + pattern match or `:filelib.wildcard/1` |

**Estimated effort:** 4-6 hours
**Dependencies:** None (stdlib)

#### 2.2 File Edit Skill
**Current:** desktop_commander edit_block
**Replacement:** Native diff/patch

```elixir
# Research needed:
- [ ] String replacement with context validation
- [ ] Fuzzy matching for moved code
- [ ] Undo/history support?
- [ ] Conflict detection
- [ ] Line-based vs character-based edits
```

**Estimated effort:** 2-3 hours
**Dependencies:** None

---

### 3. Terminal Skills (Priority: MEDIUM)

#### 3.1 Command Execution
**Current:** desktop_commander start_process, exec
**Replacement:** Native Elixir Port

```elixir
# Research needed:
- [ ] Port vs System.cmd - pros/cons
- [ ] Interactive process handling (stdin/stdout)
- [ ] PTY allocation for terminal apps
- [ ] Process supervision and cleanup
- [ ] Command sandboxing/whitelisting
- [ ] Environment variable handling
- [ ] Working directory management
- [ ] Timeout and resource limits
```

**Security considerations:**
```elixir
# Must implement:
- [ ] Command whitelist (no arbitrary execution)
- [ ] Argument sanitization (no shell injection)
- [ ] Resource limits (timeout, memory)
- [ ] Audit logging
```

**Estimated effort:** 6-8 hours
**Dependencies:** None (stdlib Port)

---

### 4. Browser Skills (Priority: LOW)

#### 4.1 Browser Automation
**Current:** `@modelcontextprotocol/server-puppeteer` (Node.js)
**Options:**

| Option | Pros | Cons |
|--------|------|------|
| **Keep external** | Works, full Chrome | Slow, complex |
| **Wallaby** | Elixir native, good API | Primarily for testing |
| **ChromeRemoteInterface** | Direct CDP access | Low-level, complex |
| **Playwright Elixir** | Modern, cross-browser | Wrapper, still external |
| **Splash** | Docker service, Lua scripts | Another service |

```elixir
# Research needed:
- [ ] Evaluate Wallaby for general automation
- [ ] Chrome DevTools Protocol direct implementation
- [ ] Headless Chrome management in Elixir
- [ ] Screenshot capture and encoding
- [ ] PDF generation
- [ ] Cookie/session management
```

**Recommendation:** Keep puppeteer external for now, or use simple HTTP-based screenshot service.

**Estimated effort:** 20+ hours for full native implementation
**Dependencies:** Complex - needs Chrome/Chromium

---

### 5. Reasoning Skills (Priority: MEDIUM)

#### 5.1 Sequential Thinking
**Current:** `@modelcontextprotocol/server-sequential-thinking` (Node.js)
**Replacement:** Pure data structure (trivial)

```elixir
# This is literally just:
defmodule Mimo.Skills.Thinking do
  def sequential_thinking(%{thought: t, number: n, total: total, next_needed: next}) do
    {:ok, %{
      thought: t,
      thought_number: n,
      total_thoughts: total,
      next_thought_needed: next,
      timestamp: DateTime.utc_now()
    }}
  end
end
```

**Estimated effort:** 30 minutes
**Dependencies:** None

#### 5.2 Planning Skill (NEW)
**Proposal:** Built-in task decomposition

```elixir
# Research needed:
- [ ] Task breakdown algorithms
- [ ] Dependency graph for subtasks
- [ ] Integration with Procedural Store
- [ ] Progress tracking
```

**Estimated effort:** 4-6 hours

---

### 6. Code Execution Skills (Priority: LOW)

#### 6.1 Safe Code Execution
**Proposal:** Sandboxed code runners

```elixir
# Research needed:
- [ ] Docker-based sandboxing
- [ ] WASM-based sandboxing (Wasmex)
- [ ] Resource limits (CPU, memory, time)
- [ ] Network isolation
- [ ] Filesystem isolation
- [ ] Language support: Python, Node, Shell

# Security critical:
- [ ] No access to host filesystem
- [ ] No network by default
- [ ] Strict timeout enforcement
- [ ] Output size limits
```

**Options:**
| Option | Security | Performance | Complexity |
|--------|----------|-------------|------------|
| Docker containers | High | Slow startup | Medium |
| Firecracker microVMs | Very High | Fast | High |
| WASM (Wasmex) | High | Fast | Medium |
| gVisor | High | Medium | High |

**Estimated effort:** 20+ hours
**Dependencies:** Docker or Wasmex

---

## Implementation Priority

### Phase 1: Quick Wins (Week 1)
1. ✅ **fetch** - Native HTTP (2-4 hours)
2. ✅ **exa_search** - Direct API (1-2 hours)
3. ✅ **sequential_thinking** - Data structure (30 min)

### Phase 2: File Operations (Week 2)
4. **file_read/write/list** - Native File (4-6 hours)
5. **file_edit** - String replacement (2-3 hours)
6. **file_search** - Pattern matching (2-3 hours)

### Phase 3: Terminal (Week 3)
7. **exec_command** - Secure Port (6-8 hours)
8. **process_management** - Supervision (4-6 hours)

### Phase 4: Advanced (Future)
9. **browser** - Evaluate options
10. **code_execution** - Sandboxed runners

---

## Skill Interface Spec

All native skills should implement this behaviour:

```elixir
defmodule Mimo.Skills.Behaviour do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback execute(args :: map()) :: {:ok, any()} | {:error, any()}
end

# Example implementation:
defmodule Mimo.Skills.Native.Fetch do
  @behaviour Mimo.Skills.Behaviour
  
  @impl true
  def name, do: "fetch"
  
  @impl true
  def description, do: "Fetch content from URLs"
  
  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        url: %{type: "string", description: "URL to fetch"},
        format: %{type: "string", enum: ["text", "html", "json", "markdown"]}
      },
      required: ["url"]
    }
  end
  
  @impl true
  def execute(%{"url" => url} = args) do
    format = Map.get(args, "format", "text")
    # Implementation here
  end
end
```

---

## Testing Strategy

```elixir
# Each skill needs:
1. Unit tests for core logic
2. Integration tests with real services (where applicable)
3. Security tests (injection, traversal, etc.)
4. Performance benchmarks vs external MCP

# Test structure:
test/
  mimo/
    skills/
      native/
        fetch_test.exs
        file_test.exs
        terminal_test.exs
        ...
```

---

## Migration Path

1. **Parallel implementation** - Native skills alongside MCP
2. **Feature flag** - `USE_NATIVE_SKILLS=true`
3. **Gradual rollout** - One skill at a time
4. **Deprecation** - Remove MCP skills after validation
5. **Cleanup** - Remove skills.json, catalog, client

---

## Success Metrics

| Metric | Current (MCP) | Target (Native) |
|--------|---------------|-----------------|
| Skill startup time | 5-30s | <100ms |
| Memory per skill | ~50MB (Node) | ~0 (same process) |
| Tool call latency | 500ms+ | <50ms |
| External dependencies | 5+ npm packages | 0 |
| Lines of code | ~500 (wrapper) | ~1000 (implementation) |

---

## Open Questions

1. **Browser automation** - Keep external or invest in native?
2. **Code execution** - Docker, WASM, or skip entirely?
3. **MCP compatibility** - Should native skills still speak MCP protocol for external clients?
4. **Plugin system** - Allow users to add custom skills?

---

## Next Steps

1. [ ] Review this spec
2. [ ] Prioritize which skills to implement first
3. [ ] Create implementation tickets
4. [ ] Start with fetch (easiest win)
5. [ ] Benchmark and validate

---

## References

- [Elixir File module](https://hexdocs.pm/elixir/File.html)
- [HTTPoison](https://hexdocs.pm/httpoison)
- [Floki HTML parser](https://hexdocs.pm/floki)
- [Exa API docs](https://docs.exa.ai)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Wasmex](https://hexdocs.pm/wasmex)
