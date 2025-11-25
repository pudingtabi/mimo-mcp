# Mimo-MCP Gateway v2.2

A universal MCP (Model Context Protocol) gateway with **multi-protocol access** - HTTP/REST, OpenAI-compatible API, CLI, and stdio MCP. Powered by hybrid AI intelligence (OpenRouter + Ollama).

[![Elixir](https://img.shields.io/badge/Elixir-1.12+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is Mimo?

Mimo is an **intelligent Memory OS** that provides:
- 🌐 **Multi-Protocol Access**: HTTP/REST, OpenAI-compatible, CLI, and MCP stdio
- 🧠 **Meta-Cognitive Router**: Intelligent query classification to memory stores
- 🔗 Combines multiple MCP tool servers into one unified interface
- 💾 Stores episodic memories in SQLite with vector embeddings
- 🔄 Hot-reloads external skills without restart
- 🛡️ Gracefully degrades when services are unavailable

---

## Quick Start

### Option 1: HTTP API (Recommended)

```bash
# Start the server
mix deps.get && mix run --no-halt

# Query via HTTP
curl -X POST http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "How do I center a div with Flexbox?"}'

# Health check
curl http://localhost:4000/health
```

### Option 2: CLI

```bash
# Build the CLI
cd cmd/mimo && go build -o mimo .

# Natural language query
./mimo ask "How do I center a div with Flexbox?"

# Direct tool execution
./mimo run search_vibes --query "dark atmosphere" --limit 5

# Shell pipeline
git diff | ./mimo ask "Write a commit message for this"
```

### Option 3: MCP stdio (VS Code)

Add to `~/.vscode/mcp.json`:

```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "ssh",
      "args": ["-o", "BatchMode=yes", "root@YOUR_VPS_IP", "/usr/local/bin/mimo-mcp-stdio"]
    }
  }
}
```

---

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | System health check |
| `/v1/mimo/ask` | POST | Natural language query via Meta-Cognitive Router |
| `/v1/mimo/tool` | POST | Direct tool execution |
| `/v1/mimo/tools` | GET | List available tools |
| `/v1/chat/completions` | POST | OpenAI-compatible endpoint |
| `/v1/models` | GET | List models (OpenAI format) |

### Example: Ask Endpoint

```bash
curl -X POST http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MIMO_API_KEY" \
  -d '{
    "query": "Fix the null pointer bug in authenticate_user",
    "context_id": "session_123",
    "timeout_ms": 5000
  }'
```

Response:
```json
{
  "query_id": "uuid-1234",
  "router_decision": {
    "primary_store": "procedural",
    "confidence": 0.94,
    "reasoning": "Code syntax detected; 'bug' and 'fix' keywords"
  },
  "results": {
    "episodic": [...],
    "semantic": null,
    "procedural": null
  },
  "synthesis": "Based on past debugging sessions...",
  "latency_ms": 42
}
```

### Example: OpenAI-Compatible

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mimo-polymorphic-1",
    "messages": [{"role": "user", "content": "Find authentication bugs"}]
  }'
```

Works with LangChain, AutoGPT, Continue.dev:

```python
from langchain.chat_models import ChatOpenAI

mimo = ChatOpenAI(
    openai_api_base="http://localhost:4000/v1",
    model_name="mimo-polymorphic-1",
    api_key="mimo-local"
)
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                              │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
│ GitHub      │ Terminal/   │ Generic IDE │ LangChain/  │ curl/   │
│ Copilot CLI │ Bash        │ Plugin      │ AutoGPT     │ HTTP    │
└──────┬──────┴──────┬──────┴──────┬──────┴──────┬──────┴────┬────┘
       │ stdio       │ subprocess  │ HTTP        │ HTTPS      │ HTTP
       ▼             ▼             ▼             ▼            ▼
┌─────────────────────────────────────────────────────────────────┐
│              Universal Aperture: Protocol Adapters               │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ MCP Adapter │ CLI Adapter │ HTTP/REST   │ OpenAI Adapter        │
│ (stdio)     │ (Go binary) │ (Phoenix)   │ (/v1/chat/completions)│
└──────┬──────┴──────┬──────┴──────┬──────┴───────────┬───────────┘
       └─────────────┴─────────────┴───────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Core: Mimo Memory OS                          │
├─────────────────────────────────────────────────────────────────┤
│  Port: QueryInterface              Port: ToolInterface           │
├─────────────────────────────────────────────────────────────────┤
│                   Meta-Cognitive Router                          │
│            (Classify → Route to appropriate store)               │
├─────────────┬─────────────────────────┬─────────────────────────┤
│ Episodic    │ Semantic Store          │ Procedural Store        │
│ Store       │ (Graph/JSON-LD)         │ (Rule Engine)           │
│ (Vector/SQL)│                         │                         │
└─────────────┴─────────────────────────┴─────────────────────────┘
```

---

## Current Tool Stack (46+ tools)

| Skill | Tools | Description |
|-------|-------|-------------|
| **mimo brain** | 3 | `ask_mimo`, `mimo_store_memory`, `mimo_reload_skills` |
| **filesystem** | 14 | Read, write, search, edit files |
| **fetch** | 4 | HTTP requests (txt, json, html, markdown) |
| **exa_search** | 2 | Web search via Exa AI |
| **playwright** | 22 | Browser automation & UI testing |
| **sequential_thinking** | 1 | Structured reasoning |

### Configure Skills

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

## Installation

### Docker (Recommended for VPS)

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp
docker-compose up -d

# Pull embedding model
docker exec mimo-ollama ollama pull nomic-embed-text
```

### Local Development

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

mix deps.get
mix ecto.create
mix ecto.migrate
mix run --no-halt
```

### Build CLI

```bash
cd cmd/mimo
go build -o mimo .
sudo mv mimo /usr/local/bin/
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MIMO_HTTP_PORT` | 4000 | HTTP gateway port |
| `MIMO_API_KEY` | (none) | API key for authentication |
| `OPENROUTER_API_KEY` | (none) | AI reasoning (OpenRouter) |
| `OLLAMA_URL` | localhost:11434 | Embeddings server |
| `EXA_API_KEY` | (none) | Web search |
| `MCP_PORT` | 9000 | MCP stdio port |
| `LOGGER_LEVEL` | info | Set to `none` for stdio |

---

## CLI Usage

```bash
# Natural language query
mimo ask "How do I center a div with Flexbox?"

# Vector similarity search
mimo run search_vibes --query "mysterious atmosphere" --limit 5

# Store a fact
mimo run store_fact --content "User prefers dark mode" --category fact

# Shell pipeline (git commit message generator)
git diff | mimo ask "Write a concise commit message" | git commit -F -

# Sandbox mode (safe for untrusted scripts)
mimo --sandbox ask "What are best practices for error handling?"

# List available tools
mimo tools

# Health check
mimo health
```

---

## VS Code Integration

### Remote VPS Setup

1. **Generate SSH key:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

2. **Create wrapper script on VPS:**
```bash
cat > /usr/local/bin/mimo-mcp-stdio << 'EOF'
#!/bin/bash
exec docker exec -i mimo-mcp mix run -e "Mimo.McpCli.run()" 2>/dev/null | grep "^{"
EOF
chmod +x /usr/local/bin/mimo-mcp-stdio
```

3. **Configure VS Code** (`~/.vscode/mcp.json`):
```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "ssh",
      "args": [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "root@<YOUR_VPS_IP>",
        "/usr/local/bin/mimo-mcp-stdio"
      ]
    }
  }
}
```

---

## API Documentation

Full OpenAPI 3.1 specification available at `priv/openapi.yaml`.

---

## Development

```bash
# Run tests
mix test

# Format code
mix format

# Check container status
docker-compose ps
docker logs -f mimo-mcp
```

---

## Roadmap

- [x] HTTP/REST Gateway (Phoenix)
- [x] OpenAI-compatible endpoint
- [x] CLI wrapper (Go)
- [x] Meta-Cognitive Router
- [x] Telemetry & metrics
- [ ] Semantic Store (Graph/JSON-LD)
- [ ] Procedural Store (Rule Engine)
- [ ] Rust NIFs for vector math
- [ ] WebSocket transport

---

## License

MIT License - see [LICENSE](LICENSE)

---

Built with ❤️ using Elixir/OTP
