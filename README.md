# Mimo-MCP Gateway v2.5.0

A universal MCP (Model Context Protocol) gateway with **multi-protocol access** - HTTP/REST, OpenAI-compatible API, WebSocket Synapse, and stdio MCP. Features vector memory storage with semantic search and a **Synthetic Cortex** for intelligent agent memory.

[![Elixir](https://img.shields.io/badge/Elixir-1.12+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## ✅ What Works (v2.5.0)

This section provides an honest assessment of current functionality:

### Feature Status Matrix

| Feature | Status | Version | Notes |
|---------|--------|---------|-------|
| HTTP/REST Gateway | ✅ Production Ready | v2.5.0 | Fully operational on port 4000 |
| MCP stdio Protocol | ✅ Production Ready | v2.5.0 | Compatible with Claude Desktop, VS Code |
| Native Elixir Tools | ✅ Production Ready | v2.5.0 | 24 native tools (15 core + 9 internal), zero NPX deps |
| Episodic Memory | ✅ Production Ready | v2.5.0 | SQLite + Ollama embeddings |
| **Working Memory** | ✅ Production Ready | v2.5.0 | ETS-backed short-term buffer with TTL |
| **Memory Consolidation** | ✅ Production Ready | v2.5.0 | Automatic working → long-term transfer |
| **Forgetting & Decay** | ✅ Production Ready | v2.5.0 | Exponential decay with importance weighting |
| **Hybrid Retrieval** | ✅ Production Ready | v2.5.0 | Multi-factor scoring (semantic + recency + importance) |
| **Memory Router** | ✅ Production Ready | v2.5.0 | Unified interface to all memory stores |
| Rate Limiting | ✅ Production Ready | v2.5.0 | Token bucket at 60 req/min |
| API Key Auth | ✅ Production Ready | v2.5.0 | Constant-time comparison |
| Tool Registry | ✅ Production Ready | v2.5.0 | Thread-safe GenServer |
| Hot Reload | ✅ Production Ready | v2.5.0 | Distributed locking |
| **Semantic Store v3.0** | ✅ Production Ready | v2.5.0 | Schema, Ingestion, Query, Inference - 74 tests |
| **Procedural Store** | ✅ Production Ready | v2.5.0 | FSM, Execution, Validation - 55 tests |
| **Rust NIFs** | ✅ Production Ready | v2.5.0 | SIMD vector math (3-7x speedup) - 52 tests |
| **WebSocket Synapse** | ✅ Production Ready | v2.5.0 | Real-time channels - 72 tests |
| **Diagnostics Tool** | ✅ Production Ready | v2.5.0 | Multi-language compile/lint/typecheck |
| **Code Symbols** | ✅ Production Ready | v2.5.0 | Tree-sitter powered code analysis |
| **Library Discovery** | ✅ Production Ready | v2.5.0 | Auto-discover project dependencies |
| Error Handling | ✅ Production Ready | v2.5.0 | Circuit breaker + retry |

### Production Ready
- **HTTP/REST Gateway** - Fully operational on port 4000
- **MCP stdio Protocol** - Compatible with Claude Desktop, VS Code Copilot
- **Episodic Memory** - SQLite + Ollama embeddings with semantic search
- **Working Memory** - ETS-backed short-term buffer with configurable TTL (default 5 min)
- **Memory Consolidation** - Automatic transfer from working to long-term memory based on importance
- **Forgetting & Decay** - Exponential decay scoring with importance weighting and access boosting
- **Hybrid Retrieval** - Multi-factor ranking combining semantic similarity, recency, importance, and popularity
- **Memory Router** - Unified API routing queries to appropriate memory stores (working, episodic, semantic, procedural)
- **Rate Limiting** - Token bucket at 60 req/min per IP
- **API Key Authentication** - Secure endpoint protection with constant-time comparison
- **Tool Registry** - Thread-safe GenServer (`Mimo.ToolRegistry`) with distributed coordination via `:pg`
- **Process Registry** - Elixir's built-in `Registry` (`Mimo.Skills.Registry`) for skill process lookups
- **Hot Reload** - Update skills without restart (with distributed locking)
- **Semantic Store v3.0** - Triple-based knowledge graph with Schema, Ingestion, Query, and Inference engines (74 tests passing)
- **Procedural Store** - FSM engine with Registration, Execution, Validation, and concurrent execution (55 tests passing)
- **Rust NIFs** - SIMD-accelerated vector math providing 3-7x speedup over pure Elixir (52 tests passing)
- **WebSocket Synapse** - Real-time bidirectional cognitive signaling via Phoenix Channels (72 tests passing)
- **Diagnostics Tool** - Multi-language compile/lint/typecheck (Elixir, TypeScript, Python, Rust, Go)
- **Code Symbols** - Tree-sitter powered code analysis with symbol extraction and call graphs
- **Library Discovery** - Auto-discover and cache project dependencies (Hex, NPM, PyPI, Crates)
- **Test Suite** - 700+ tests passing (including 100 integration tests)

### Security Hardened (v2.3.1)
- **SecureExecutor** - Command whitelist (docker, node, python, etc.), argument sanitization
- **Config Validator** - JSON schema validation, dangerous pattern detection, path traversal prevention
- **Memory Cleanup** - Automatic TTL-based cleanup (30 days default), 100K memory limit
- **ACID Transactions** - Memory persistence with proper transaction handling
- **Telemetry** - Security event logging for audit trails

### Known Limitations
- Ollama required for embeddings - falls back to simple hashing if unavailable
- Single-node deployment tested; distributed mode experimental
- Semantic search is O(n) - limited to ~50K entities for optimal performance
- Terminal commands execute in sandboxed environment - use in trusted environments
- Vision tool requires OPENROUTER_API_KEY for image analysis

---

## What is Mimo?

Mimo is an **intelligent Memory OS** that provides:
- 🌐 **Multi-Protocol Access**: HTTP/REST, OpenAI-compatible, WebSocket, and MCP stdio
- 🧠 **Meta-Cognitive Router**: Intelligent query classification to memory stores
- 🔗 **24 Native Tools**: 15 core tools + 9 internal tools (zero NPX dependencies)
- 💾 **Vector Memory**: SQLite + Ollama embeddings for semantic search
- 📊 **Semantic Store**: Triple-based knowledge graph for exact relationships
- ⚙️ **Procedural Store**: Deterministic state machine execution
- 🦀 **Rust NIFs**: SIMD-accelerated vector operations (3-7x speedup)
- ⚡ **WebSocket Synapse**: Real-time bidirectional cognitive signaling
- 🔬 **Diagnostics**: Multi-language compile/lint/typecheck support
- 📦 **Library Discovery**: Auto-discover project dependencies
- 🔄 **Hot-Reload**: Update skills without restart
- 🛡️ **Rate Limiting**: Built-in DoS protection (60 req/min)
- 🔐 **API Key Auth**: Secure your endpoints

### Deployment Options

| Option | Best For | Requirements |
|--------|----------|--------------|
| **Option 0: Single Binary** | Enterprise/Production | None (Self-contained) |
| **Option 1: Local + Docker** | Most users | Docker Desktop |
| **Option 2: Local Native** | Developers | Elixir 1.12+, Ollama |
| **Option 3: VPS** | Always-on, multi-device | VPS with 2GB+ RAM |

---

## Quick Start

### Option 0: Single Binary (No Dependencies)

Download the latest release for your platform (Linux, macOS, Windows).

```bash
# Run in MCP mode (Claude/VS Code)
./mimo

# Run as HTTP Server
./mimo server -p 4000
```

**Configure Claude Desktop:**

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/absolute/path/to/mimo",
      "args": ["stdio"],
      "env": {
        "MIMO_ROOT": "/absolute/path/to/workspace"
      }
    }
  }
}
```

### Option 1: Local Machine (Docker)

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed

```bash
# Clone the repo
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Start services (Mimo + Ollama)
docker-compose up -d

# Pull embedding model (~639MB, one-time download)
docker exec mimo-ollama ollama pull qwen3-embedding:0.6b

# Run database migrations
docker exec mimo-mcp sh -c "MIX_ENV=prod mix ecto.migrate"

# Test - should return {"status":"healthy"...}
curl http://localhost:4000/health
```

**Configure Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json` on Mac):

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/absolute/path/to/mimo-mcp/bin/mimo",
      "args": ["stdio"],
      "env": {
        "MIMO_ROOT": "/absolute/path/to/workspace"
      }
    }
  }
}
```

---

### Option 2: Local without Docker (Native Elixir)

**Prerequisites:** Elixir 1.12+, Erlang 24+, SQLite3, [Ollama](https://ollama.ai)

```bash
# Install Ollama and pull embedding model
curl -fsSL https://ollama.ai/install.sh | sh
ollama pull qwen3-embedding:0.6b

# Clone and setup
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Configure environment (optional but recommended)
cp .env.example .env
# Edit .env to add your OPENROUTER_API_KEY (free at https://openrouter.ai/keys)

mix deps.get
mix ecto.create
mix ecto.migrate

# Run server
./bin/mimo server
```

---

### Option 3: VPS Deployment (Remote Access)

For accessing Mimo from multiple machines or keeping it always-on:

```bash
# On your VPS
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Configure environment
cat > .env << EOF
MIMO_API_KEY=$(openssl rand -hex 32)
MIMO_HOST=your-vps-ip
EOF

# Deploy
docker-compose up -d
docker exec mimo-ollama ollama pull qwen3-embedding:0.6b
docker exec mimo-mcp sh -c "MIX_ENV=prod mix ecto.migrate"

# Open firewall
sudo ufw allow 4000/tcp
```

---

## API Reference

### Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | No | System health check |
| `/v1/mimo/ask` | POST | Yes | Natural language query |
| `/v1/mimo/tool` | POST | Yes | Execute a specific tool |
| `/v1/mimo/tools` | GET | Yes | List available tools |
| `/v1/chat/completions` | POST | Yes | OpenAI-compatible endpoint |
| `/v1/models` | GET | Yes | List models (OpenAI format) |

### Authentication

All `/v1/*` endpoints require an API key:

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" http://localhost:4000/v1/mimo/tools
```

### Example: Store a Memory

```bash
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "tool": "store_fact",
    "arguments": {
      "content": "User prefers dark mode themes",
      "category": "observation",
      "importance": 0.8
    }
  }'
```

Response:
```json
{
  "data": {"id": 1, "stored": true},
  "status": "success",
  "latency_ms": 45.2,
  "tool_call_id": "uuid-1234"
}
```

### Example: Search Memories

```bash
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "tool": "search_vibes",
    "arguments": {
      "query": "user preferences",
      "limit": 5,
      "threshold": 0.3
    }
  }'
```

Response:
```json
{
  "data": [
    {
      "id": 1,
      "content": "User prefers dark mode themes",
      "category": "observation",
      "similarity": 0.87,
      "importance": 0.8
    }
  ],
  "status": "success",
  "latency_ms": 12.5
}
```

### Example: Natural Language Query

```bash
curl -X POST http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"query": "What do you know about user preferences?"}'
```

---

## MCP stdio Protocol

For Claude Desktop, VS Code, or other MCP clients:

### Test MCP Locally

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"},"capabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | ./bin/mimo stdio
```

### Claude Desktop Configuration

**macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`  
**Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "mimo": {
      "command": "ssh",
      "args": [
        "-o", "StrictHostKeyChecking=no",
        "root@YOUR_VPS_IP",
        "cd /path/to/mimo-mcp && ./bin/mimo stdio"
      ]
    }
  }
}
```

### VS Code Configuration

Add to `~/.vscode/mcp.json`:

```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "ssh",
      "args": [
        "-o", "BatchMode=yes",
        "root@YOUR_VPS_IP",
        "cd /path/to/mimo-mcp && ./bin/mimo stdio"
      ]
    }
  }
}
```

---

## Available Tools (24 Native)

Mimo provides **24 native Elixir tools** with zero external dependencies. Managed by the **Tool Registry** (`Mimo.ToolRegistry`).

### Tool Architecture (v2.5.0)

| Category | Count | Description |
|----------|-------|--------------|
| **Internal** | 9 | Memory & procedure operations (ask_mimo, store_fact, search_vibes, memory, ingest, run_procedure, procedure_status, list_procedures, reload) |
| **Mimo.Tools** | 15 | Consolidated native tools (file, terminal, fetch, think, search, vision, blink, browser, diagnostics, etc.) |

### Consolidated Core Tools (Mimo.Tools)

Each tool handles multiple operations via the `operation` parameter:

| Tool | Operations | Description |
|------|------------|-------------|
| `file` | read, write, ls, read_lines, insert_after, insert_before, replace_lines, delete_lines, search, replace_string, edit, list_directory, get_info, move, create_directory, read_multiple, list_symbols, read_symbol, search_symbols, **glob**, **multi_replace**, **diff** | All file system operations |
| `terminal` | execute, start_process, read_output, interact, kill, force_kill, list_sessions, list_processes | Command execution with **cwd**, **env**, **shell** options |
| `fetch` | text, html, json, markdown, raw | HTTP requests with format conversion |
| `think` | thought, plan, sequential | Cognitive operations and reasoning |
| `web_parse` | (html→markdown) | Convert HTML to clean Markdown |
| `search` | web, code, images | Web search via DuckDuckGo, Bing, or Brave (auto-fallback, no API key required) |
| `web_extract` | (url→content) | Extract clean content from web pages (Readability-style) |
| `sonar` | (auto-detect platform) | UI accessibility scanner (Linux/macOS) |
| `vision` | (image→analysis) | Analyze images using vision-capable LLM (Mistral via OpenRouter) |
| `knowledge` | query, teach, traverse, explore, node, path, stats, link, link_memory, sync_dependencies, neighborhood | Unified knowledge graph (SemanticStore + Synapse) |
| `blink` | fetch, analyze, smart | HTTP-level browser emulation to bypass bot detection |
| `browser` | fetch, screenshot, pdf, evaluate, interact, test | Full Puppeteer browser automation with stealth mode |
| `code_symbols` | parse, symbols, references, search, definition, call_graph, index | Tree-sitter powered code analysis |
| `library` | get, search, ensure, **discover**, stats | Package documentation lookup with auto-discovery |
| `diagnostics` | check, lint, typecheck, all | **Multi-language** compile/lint errors (Elixir, TypeScript, Python, Rust, Go) |
| `cognitive` | assess, gaps, query, can_answer, suggest, stats | Epistemic uncertainty and meta-cognition |
| `graph` | (deprecated) | Use `knowledge` tool instead |

### Internal Tools

| Tool | Description | Required Args |
|------|-------------|---------------|
| `ask_mimo` | Query Mimo's memory system | `query` |
| `store_fact` | [Deprecated: use memory] Store facts/observations | `content`, `category` |
| `search_vibes` | [Deprecated: use memory] Vector similarity search | `query` |
| `memory` | Unified memory operations (store, search, list, delete, stats, decay_check) | `operation` |
| `ingest` | Ingest file content into memory with chunking | `path` |
| `run_procedure` | Execute a registered procedure as FSM | `name` |
| `procedure_status` | Check status of procedure execution | `execution_id` |
| `list_procedures` | List all registered procedures | (none) |
| `mimo_reload_skills` | Hot-reload skills without restart | (none) |

### Example Usage

```bash
# File operations
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "file", "arguments": {"operation": "read", "path": "README.md"}}'

# File glob (new)
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "file", "arguments": {"operation": "glob", "pattern": "**/*.ex", "base_path": "lib/"}}'

# Terminal command with cwd and env (new)
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "terminal", "arguments": {"command": "npm test", "cwd": "/app/frontend", "env": {"NODE_ENV": "test"}}}'

# Fetch with format
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "fetch", "arguments": {"url": "https://api.example.com", "format": "json"}}'

# Web search
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "search", "arguments": {"query": "Elixir programming"}}'

# Diagnostics - get compile/lint errors (new)
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "diagnostics", "arguments": {"operation": "all", "path": "lib/", "language": "elixir"}}'

# Code symbols - list functions in file (new)
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "code_symbols", "arguments": {"operation": "symbols", "path": "lib/mimo/tools.ex", "kind": "function"}}'

# Library discovery - auto-discover dependencies (new)
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"tool": "library", "arguments": {"operation": "discover", "path": "/app"}}'
```

### Tool Discovery

```elixir
# List all registered tools (IEx)
Mimo.ToolRegistry.list_all_tools() |> length()
# => 24 (9 internal + 15 core)

# Get tool owner
Mimo.ToolRegistry.get_tool_owner("file")
# => {:ok, {:mimo_core, :file}}

# List available tools via dispatch
Mimo.Tools.list_tools()
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                              │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ Claude      │ VS Code     │ curl/HTTP   │ LangChain/AutoGPT     │
│ Desktop     │ Copilot     │ clients     │                       │
└──────┬──────┴──────┬──────┴──────┬──────┴───────────┬───────────┘
       │ stdio       │ stdio       │ HTTP             │ HTTP
       ▼             ▼             ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│              Universal Aperture: Protocol Adapters               │
├─────────────────────────┬───────────────────────────────────────┤
│ MCP Adapter (stdio)     │ HTTP Gateway (Phoenix)                │
│ lib/mimo/mcp_server     │ Port 4000                             │
└───────────┬─────────────┴───────────────────┬───────────────────┘
            └─────────────┬───────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Core: Mimo Memory OS                          │
├─────────────────────────────────────────────────────────────────┤
│  QueryInterface              │           ToolInterface           │
│  (Natural Language)          │           (Direct Execution)      │
├─────────────────────────────────────────────────────────────────┤
│                   Memory Router (Unified API)                    │
│         (Route to: working | episodic | semantic | procedural)   │
├─────────────────────────────────────────────────────────────────┤
│  Working Memory │ Consolidator │ Forgetting │ Hybrid Retrieval   │
│  (ETS Buffer)   │ (WM→LTM)     │ (Decay)    │ (Multi-factor)     │
├─────────────┬─────────────────────────┬─────────────────────────┤
│ Episodic    │ Semantic Store          │ Procedural Store        │
│ Store ✅    │ ✅ Production           │ ✅ Production           │
│ SQLite +    │ Triple-based            │ State Machine           │
│ Vectors     │ Knowledge Graph         │ Execution               │
└─────────────┴─────────────────────────┴─────────────────────────┘
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MIMO_HTTP_PORT` | 4000 | HTTP gateway port |
| `MIMO_HOST` | localhost | Public hostname/IP |
| `MIMO_API_KEY` | (none) | API key for authentication |
| `MIMO_SECRET_KEY_BASE` | (auto) | Phoenix secret key |
| `OLLAMA_URL` | http://ollama:11434 | Embeddings server |
| `OPENROUTER_API_KEY` | (none) | Vision/AI reasoning (optional) |
| `LOGGER_LEVEL` | info | `none` for clean stdio |

---

## Development

### Local Setup

```bash
# Install dependencies
mix deps.get

# Create database
mix ecto.create
mix ecto.migrate

# Run server
./bin/mimo server

# Run tests
mix test
```

### Docker Commands

```bash
# View logs
docker logs -f mimo-mcp

# Restart
docker-compose restart mimo

# Rebuild
docker-compose up -d --build

# Check migrations
docker exec mimo-mcp mix ecto.migrations

# Run prod migrations
docker exec mimo-mcp sh -c "MIX_ENV=prod mix ecto.migrate"
```

---

## Security

- **API Key**: Set `MIMO_API_KEY` in `.env` to protect endpoints
- **Rate Limiting**: 60 requests/minute per IP (configurable)
- **Firewall**: Only expose port 4000 (Ollama stays internal)
- **HTTPS**: Use nginx/Caddy reverse proxy for production

### Example Caddy Config

```
mimo.yourdomain.com {
    reverse_proxy localhost:4000
}
```

---

## 🧠 Roadmap: The Path to Synthetic Cognition

Our goal is to evolve Mimo from a simple gateway into a complete **Memory Operating System** — a Synthetic Cortex for AI agents.

### Phase 1: The Foundation ✅
*Infrastructure and Basic Recall*

- [x] **Universal Gateway:** HTTP/REST (Phoenix) & OpenAI-compatible endpoints
- [x] **Protocol Bridge:** MCP stdio adapter for Claude Desktop & VS Code
- [x] **Episodic Memory:** Vector storage using SQLite + Ollama Embeddings
- [x] **Security:** API Key authentication and Token Bucket rate limiting
- [x] **Meta-Cognitive Router:** Intent classification (routing queries to the correct memory system)

### Phase 2: The Cognitive Layers ✅
*Structuring Knowledge and Behavior*

| Component | Simple Pitch | Complex Architecture | Status |
|-----------|--------------|---------------------|--------|
| **Semantic Store** | Vector memory is fuzzy—it knows 'King' and 'Queen' are similar. The Semantic Store is precise—it knows 'King' *is married to* 'Queen'. It's the difference between a vibe and a fact. | Lightweight Knowledge Graph using SQLite Recursive CTEs as a Triple Store (Subject → Predicate → Object). Enables multi-hop reasoning with forward/backward chaining inference. | ✅ Production Ready |
| **Procedural Store** | LLMs are creative, but sometimes you need them to follow a checklist exactly. This gives Mimo 'muscle memory'—stored recipes for tasks that need to happen the same way every time. | Deterministic Finite Automata (DFA) engine using `gen_statem`. Executes rigid state machine pipelines with automatic retries and rollback support. | ✅ Production Ready |

### Phase 3: The Nervous System ✅
*Speed and Connectivity*

| Component | Simple Pitch | Complex Architecture | Status |
|-----------|--------------|---------------------|--------|
| **Rust NIFs** | Elixir manages the traffic; Rust does the heavy lifting. We swap the engine while the car is driving to make math calculations instant. | Zero-copy FFI via `rustler`. Offloads O(n) cosine similarity from BEAM to compiled Rust with SIMD hardware acceleration using `wide` crate. 3-7x speedup achieved. | ✅ Production Ready |
| **WebSocket Synapse** | Stop asking, start listening. Instead of polling 'Are we there yet?', Mimo pushes thoughts and results the moment they happen. | Full-Duplex State Synchronization via Phoenix Channels. Enables "Agent Interruptibility"—the server can pause generation if higher-priority events trigger. | ✅ Production Ready |

---

## Synthetic Cortex Features (v2.4.0)

### Semantic Store - The World Model

Store and query exact relationships between entities:

```elixir
# Store a fact: "Alice reports to Bob"
Mimo.SemanticStore.Repository.create(%{
  subject_id: "alice",
  subject_type: "person", 
  predicate: "reports_to",
  object_id: "bob",
  object_type: "person",
  confidence: 1.0
})

# Multi-hop traversal: "Who is in Alice's reporting chain?"
Mimo.SemanticStore.Query.transitive_closure("alice", "person", "reports_to")
# => [%Entity{id: "bob", depth: 1}, %Entity{id: "ceo", depth: 2}]
```

### Procedural Store - The Muscle Memory

Execute deterministic procedures without LLM involvement:

```elixir
# Register a procedure
Mimo.ProceduralStore.Loader.register(%{
  name: "deploy_database",
  version: "1.0",
  definition: %{
    "initial_state" => "validate",
    "states" => %{
      "validate" => %{
        "action" => %{"module" => "MyApp.Steps.Validate", "function" => "execute"},
        "transitions" => [%{"event" => "success", "target" => "provision"}]
      },
      "provision" => %{
        "action" => %{"module" => "MyApp.Steps.Provision", "function" => "execute"},
        "transitions" => [%{"event" => "success", "target" => "done"}]
      },
      "done" => %{}
    }
  }
})

# Execute procedure
{:ok, pid} = Mimo.ProceduralStore.ExecutionFSM.start_procedure("deploy_database", "1.0", %{env: "prod"})
```

### WebSocket Synapse - Real-time Cognition

Connect for streaming thoughts and interruptible execution:

```javascript
// JavaScript client
const socket = new Phoenix.Socket("/cortex", {params: {token: "..."}});
socket.connect();

const channel = socket.channel("cortex:agent-123", {api_key: "..."});
channel.join();

// Send query
channel.push("query", {q: "What do you know about users?", ref: "q1"});

// Receive streaming thoughts
channel.on("thought", ({thought, ref}) => {
  console.log(`[${thought.type}] ${thought.content}`);
});

// Receive final result
channel.on("result", ({ref, status, data, latency_ms}) => {
  console.log(`Query ${ref} completed in ${latency_ms}ms`);
});

// Interrupt long-running query
channel.push("interrupt", {ref: "q1", reason: "user cancelled"});
```

### Rust NIFs - SIMD Vector Math

High-performance vector operations:

```elixir
# Single similarity (10-40x faster than pure Elixir)
{:ok, similarity} = Mimo.Vector.Math.cosine_similarity(vec_a, vec_b)

# Batch similarity with parallel processing
{:ok, similarities} = Mimo.Vector.Math.batch_similarity(query, corpus)

# Top-k search
{:ok, results} = Mimo.Vector.Math.top_k_similar(query, corpus, 10)
```

---

## Feature Flags

Enable Synthetic Cortex modules via environment variables or config:

```bash
# Environment variables
export RUST_NIFS_ENABLED=true
export SEMANTIC_STORE_ENABLED=true
export PROCEDURAL_STORE_ENABLED=true
export WEBSOCKET_ENABLED=true
```

Or in `config/config.exs`:

```elixir
config :mimo_mcp, :feature_flags,
  rust_nifs: true,
  semantic_store: true,
  procedural_store: true,
  websocket_synapse: true
```

### Feature Flag Effects

| Flag | When Enabled | When Disabled |
|------|--------------|---------------|
| `rust_nifs` | Uses SIMD-accelerated Rust for vector math | Falls back to pure Elixir implementation |
| `semantic_store` | Semantic query routing available, triple store active | Queries use direct path |
| `procedural_store` | Procedure tools available via `ToolInterface` | Procedure-related tool calls return `{:error, :feature_disabled}` |
| `websocket_synapse` | WebSocket channels active for real-time communication | WebSocket connections rejected |

### Runtime Configuration (v2.4.0)

The `:environment` config controls runtime behavior:

```elixir
# config/runtime.exs
config :mimo_mcp,
  environment: config_env()  # :dev, :test, or :prod
```

This affects:
- **Authentication mode**: Development-only relaxed auth in dev environment
- **Rate limiting**: Stricter in production
- **Logging verbosity**: Reduced in production

Check module status:

```elixir
Mimo.Application.cortex_status()
# => %{
#   rust_nifs: %{enabled: true, loaded: true},
#   semantic_store: %{enabled: true, tables_exist: true},
#   procedural_store: %{enabled: true, tables_exist: true},
#   websocket_synapse: %{enabled: true, connections: 3}
# }
```

---

## File Structure (v2.4.0)

```
lib/
├── mimo.ex                          # Main module
├── mimo_web.ex                      # Phoenix web helpers
├── mimo/
│   ├── application.ex               # OTP application with feature flags
│   ├── cli.ex                       # Burrito CLI Entry Point
│   ├── tools.ex                     # Consolidated 11 core tools (file, terminal, fetch, vision, blink, etc.)
│   ├── tool_registry.ex             # Thread-safe tool registration
│   ├── auto_memory.ex               # Automatic memory capture
│   ├── meta_cognitive_router.ex     # Query classification router
│   ├── mcp_server/
│   │   └── stdio.ex                 # Native MCP Stdio
│   ├── skills/                      # Skill implementations
│   │   ├── network.ex               # HTTP client
│   │   ├── terminal.ex              # Command execution
│   │   ├── file_ops.ex              # File operations
│   │   ├── cognition.ex             # Thinking operations
│   │   ├── sonar.ex                 # UI accessibility scanner
│   │   └── ...
│   ├── brain/                       # Episodic memory (Working + Long-term)
│   │   ├── working_memory.ex        # ETS-backed short-term buffer
│   │   ├── consolidator.ex          # Working → Long-term transfer
│   │   ├── forgetting.ex            # Decay and importance weighting
│   │   ├── hybrid_retriever.ex      # Multi-factor scoring
│   │   └── ...
│   ├── semantic_store/              # Triple-based knowledge graph
│   ├── procedural_store/            # FSM execution engine
│   ├── synapse/                     # WebSocket channels
│   └── vector/                      # Vector math (Rust NIF + fallback)
├── mimo_web/
│   ├── endpoint.ex                  # HTTP + WebSocket endpoint
│   ├── router.ex                    # Route definitions
│   └── channels/
│       └── cortex_channel.ex        # Real-time cognitive signaling
native/
└── vector_math/                     # Rust NIF for SIMD operations
```

---

## License

MIT License - see [LICENSE](LICENSE)

---

Built with ❤️ using Elixir/OTP and Ollama

**Mimo: Where Agents Remember.**