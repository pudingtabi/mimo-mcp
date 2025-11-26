# Mimo-MCP Gateway v2.3

A universal MCP (Model Context Protocol) gateway with **multi-protocol access** - HTTP/REST, OpenAI-compatible API, WebSocket Synapse, and stdio MCP. Features vector memory storage with semantic search and a **Synthetic Cortex** for intelligent agent memory.

[![Elixir](https://img.shields.io/badge/Elixir-1.16+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is Mimo?

Mimo is an **intelligent Memory OS** that provides:
- 🌐 **Multi-Protocol Access**: HTTP/REST, OpenAI-compatible, WebSocket, and MCP stdio
- 🧠 **Meta-Cognitive Router**: Intelligent query classification to memory stores
- 🔗 **48+ Tools**: Combines filesystem, browser automation, web search, and memory tools
- 💾 **Vector Memory**: SQLite + Ollama embeddings for semantic search
- 📊 **Semantic Store**: Triple-based knowledge graph for exact relationships
- ⚙️ **Procedural Store**: Deterministic state machine execution
- 🦀 **Rust NIFs**: SIMD-accelerated vector operations
- ⚡ **WebSocket Synapse**: Real-time bidirectional cognitive signaling
- 🔄 **Hot-Reload**: Update skills without restart
- 🛡️ **Rate Limiting**: Built-in DoS protection (60 req/min)
- 🔐 **API Key Auth**: Secure your endpoints

### Deployment Options

| Option | Best For | Requirements |
|--------|----------|--------------|
| **Local + Docker** | Most users | Docker Desktop |
| **Local Native** | Developers | Elixir 1.16+, Ollama |
| **VPS** | Always-on, multi-device | VPS with 2GB+ RAM |

---

## Quick Start

### Option 1: Local Machine (No VPS Required)

Run everything on your local machine with Docker:

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed

```bash
# Clone the repo
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Start services (Mimo + Ollama)
docker-compose up -d

# Pull embedding model (~274MB, one-time download)
docker exec mimo-ollama ollama pull nomic-embed-text

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
      "command": "docker",
      "args": ["exec", "-i", "mimo-mcp", "mix", "run", "--no-halt", "-e", "Mimo.MCPServer.start_stdio()"],
      "env": {
        "LOGGER_LEVEL": "error"
      }
    }
  }
}
```

Or use the Python wrapper (simpler):

```json
{
  "mcpServers": {
    "mimo": {
      "command": "python3",
      "args": ["/path/to/mimo-mcp/mimo-mcp-stdio.py"]
    }
  }
}
```

---

### Option 2: Local without Docker (Native Elixir)

**Prerequisites:** Elixir 1.16+, Erlang 26+, SQLite3, [Ollama](https://ollama.ai)

```bash
# Install Ollama and pull embedding model
curl -fsSL https://ollama.ai/install.sh | sh
ollama pull nomic-embed-text

# Clone and setup
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp
mix deps.get
mix ecto.create
mix ecto.migrate

# Run server
mix run --no-halt
```

**Configure Claude Desktop:**

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/path/to/mimo-mcp/mimo-mcp-stdio.py"
    }
  }
}
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
docker exec mimo-ollama ollama pull nomic-embed-text
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
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 mimo-mcp-stdio.py
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
        "cd /path/to/mimo-mcp && LOGGER_LEVEL=error python3 mimo-mcp-stdio.py"
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
        "cd /path/to/mimo-mcp && LOGGER_LEVEL=error python3 mimo-mcp-stdio.py"
      ]
    }
  }
}
```

---

## Available Tools (48+)

### Internal Tools

| Tool | Description |
|------|-------------|
| `ask_mimo` | Query Mimo's memory system |
| `store_fact` | Store facts/observations with embeddings |
| `search_vibes` | Vector similarity search |
| `mimo_store_memory` | Store memory (alias) |
| `mimo_reload_skills` | Hot-reload skills without restart |

### External Skills (via MCP)

| Skill | Tools | Description |
|-------|-------|-------------|
| **filesystem** | 14 | Read, write, search, edit files |
| **playwright** | 22 | Browser automation & screenshots |
| **fetch** | 4 | HTTP requests (txt, json, html, md) |
| **exa_search** | 2 | Web search via Exa AI |
| **sequential_thinking** | 1 | Structured reasoning |

### Configure External Skills

Edit `priv/skills.json`:

```json
{
  "filesystem": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
    "env": {}
  },
  "exa_search": {
    "command": "npx",
    "args": ["-y", "exa-mcp-server"],
    "env": { "EXA_API_KEY": "${EXA_API_KEY}" }
  }
}
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
│ mimo-mcp-stdio.py       │ Port 4000                             │
└───────────┬─────────────┴───────────────────┬───────────────────┘
            └─────────────┬───────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Core: Mimo Memory OS                          │
├─────────────────────────────────────────────────────────────────┤
│  QueryInterface              │           ToolInterface           │
│  (Natural Language)          │           (Direct Execution)      │
├─────────────────────────────────────────────────────────────────┤
│                   Meta-Cognitive Router                          │
│            (Classify → Route to appropriate store)               │
├─────────────┬─────────────────────────┬─────────────────────────┤
│ Episodic    │ Semantic Store          │ Procedural Store        │
│ Store ✅    │ (Coming Soon)           │ (Coming Soon)           │
│ SQLite +    │                         │                         │
│ Vectors     │                         │                         │
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
| `OPENROUTER_API_KEY` | (none) | AI reasoning |
| `EXA_API_KEY` | (none) | Web search |
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
mix run --no-halt

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
| **Semantic Store** | Vector memory is fuzzy—it knows 'King' and 'Queen' are similar. The Semantic Store is precise—it knows 'King' *is married to* 'Queen'. It's the difference between a vibe and a fact. | Lightweight Knowledge Graph using SQLite Recursive CTEs as a Triple Store (Subject → Predicate → Object). Enables multi-hop reasoning with forward/backward chaining inference. | ✅ Implemented |
| **Procedural Store** | LLMs are creative, but sometimes you need them to follow a checklist exactly. This gives Mimo 'muscle memory'—stored recipes for tasks that need to happen the same way every time. | Deterministic Finite Automata (DFA) engine using `gen_statem`. Bypasses LLM generation for rigid state machine pipelines with automatic retries and rollback support. | ✅ Implemented |

### Phase 3: The Nervous System ✅
*Speed and Connectivity*

| Component | Simple Pitch | Complex Architecture | Status |
|-----------|--------------|---------------------|--------|
| **Rust NIFs** | Elixir manages the traffic; Rust does the heavy lifting. We swap the engine while the car is driving to make math calculations instant. | Zero-copy FFI via `rustler`. Offloads O(n) cosine similarity from BEAM to compiled Rust with SIMD hardware acceleration using `wide` crate. ~10-40x speedup. | ✅ Implemented |
| **WebSocket Synapse** | Stop asking, start listening. Instead of polling 'Are we there yet?', Mimo pushes thoughts and results the moment they happen. | Full-Duplex State Synchronization via Phoenix Channels. Enables "Agent Interruptibility"—the server can pause generation if higher-priority events trigger. | ✅ Implemented |

---

## Synthetic Cortex Features (v2.3)

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

## Architecture Philosophy

```
┌─────────────────────────────────────────────────────────────────┐
│                    THE SYNTHETIC CORTEX                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │  Episodic   │  │  Semantic   │  │ Procedural  │              │
│  │   Store     │  │   Store     │  │   Store     │              │
│  │  (Vibes)    │  │  (Facts)    │  │  (Recipes)  │              │
│  │   ✅ Done   │  │  ✅ Done    │  │  ✅ Done    │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
│         └────────────────┼────────────────┘                      │
│                          │                                       │
│                          ▼                                       │
│              ┌───────────────────────┐                          │
│              │  Meta-Cognitive Router │  ← "Which store knows?" │
│              │        ✅ Done         │                          │
│              └───────────┬───────────┘                          │
│                          │                                       │
│         ┌────────────────┼────────────────┐                      │
│         ▼                ▼                ▼                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │    HTTP     │  │     MCP     │  │  WebSocket  │              │
│  │   Gateway   │  │    stdio    │  │   Synapse   │              │
│  │   ✅ Done   │  │   ✅ Done   │  │  ✅ Done    │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│                                                                  │
│  ┌──────────────────────────────────────────────┐               │
│  │              Rust NIFs (SIMD)                 │               │
│  │         Vector Math Acceleration              │               │
│  │                 ✅ Done                        │               │
│  └──────────────────────────────────────────────┘               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**The Three Memory Systems:**
- **Episodic (Vibes):** "I remember something *like* this..." — fuzzy vector similarity
- **Semantic (Facts):** "I *know* that X is related to Y" — precise graph relationships  
- **Procedural (Recipes):** "When X happens, *always* do Y" — deterministic state machines

---

## File Structure (v2.3)

```
lib/
├── mimo.ex                          # Main module
├── mimo_web.ex                      # Phoenix web helpers
├── mimo/
│   ├── application.ex               # OTP application with feature flags
│   ├── meta_cognitive_router.ex     # Query classification
│   ├── telemetry.ex                 # Metrics
│   ├── repo.ex                      # Ecto repo
│   ├── brain/                       # Episodic memory
│   │   ├── memory.ex
│   │   ├── llm.ex
│   │   └── engram.ex
│   ├── semantic_store/              # Phase 2: Knowledge Graph
│   │   ├── triple.ex                # Ecto schema
│   │   ├── entity.ex                # Virtual entity struct
│   │   ├── query.ex                 # Recursive CTE queries
│   │   ├── repository.ex            # CRUD operations
│   │   └── inference_engine.ex      # Forward/backward chaining
│   ├── procedural_store/            # Phase 2: State Machines
│   │   ├── procedure.ex             # Ecto schema
│   │   ├── execution_fsm.ex         # gen_statem implementation
│   │   ├── step_executor.ex         # Behaviour + implementations
│   │   ├── validator.ex             # JSON schema validation
│   │   └── loader.ex                # Procedure loading & caching
│   ├── vector/                      # Phase 3: Rust NIFs
│   │   ├── math.ex                  # NIF wrapper
│   │   ├── fallback.ex              # Pure Elixir fallback
│   │   ├── supervisor.ex            # Supervisor tree
│   │   └── worker.ex                # Search utilities
│   └── synapse/                     # Phase 3: WebSocket
│       ├── connection_manager.ex    # Connection lifecycle
│       ├── interrupt_manager.ex     # Execution interruption
│       └── message_router.ex        # PubSub routing
├── mimo_web/
│   ├── endpoint.ex                  # HTTP + WebSocket
│   ├── router.ex                    # HTTP routes
│   ├── channels/
│   │   ├── cortex_channel.ex        # Real-time channel
│   │   └── presence.ex              # Agent presence tracking
│   └── controllers/
│       └── ...
native/
└── vector_math/                     # Rust NIF
    ├── Cargo.toml
    └── src/lib.rs                   # SIMD cosine similarity
priv/
└── repo/migrations/
    ├── 20241125000000_create_engrams.exs
    ├── 20251126000001_create_semantic_store.exs
    └── 20251126000002_create_procedural_store.exs
```

---

## License

MIT License - see [LICENSE](LICENSE)

---

Built with ❤️ using Elixir/OTP and Ollama

**Mimo: Where Agents Remember.**
