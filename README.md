# Mimo-MCP Gateway v2.2

A universal MCP (Model Context Protocol) gateway with **multi-protocol access** - HTTP/REST, OpenAI-compatible API, and stdio MCP. Features vector memory storage with semantic search.

[![Elixir](https://img.shields.io/badge/Elixir-1.16+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is Mimo?

Mimo is an **intelligent Memory OS** that provides:
- 🌐 **Multi-Protocol Access**: HTTP/REST, OpenAI-compatible, and MCP stdio
- 🧠 **Meta-Cognitive Router**: Intelligent query classification to memory stores
- 🔗 **48+ Tools**: Combines filesystem, browser automation, web search, and memory tools
- 💾 **Vector Memory**: SQLite + Ollama embeddings for semantic search
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

## Roadmap

- [x] HTTP/REST Gateway (Phoenix)
- [x] OpenAI-compatible endpoint
- [x] MCP stdio adapter
- [x] Vector memory (SQLite + Ollama)
- [x] Rate limiting
- [x] API key authentication
- [x] Meta-Cognitive Router
- [ ] Semantic Store (Graph/JSON-LD)
- [ ] Procedural Store (Rule Engine)
- [ ] WebSocket transport
- [ ] Rust NIFs for vector math

---

## License

MIT License - see [LICENSE](LICENSE)

---

Built with ❤️ using Elixir/OTP and Ollama
