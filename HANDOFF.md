# Mimo-MCP Handoff Document

## Current Status: ✅ Universal Aperture Architecture Implemented

**Last Updated:** 2025-11-25  
**Version:** 2.2.0

---

## New Architecture: Universal Aperture Protocol

The MCP-only architecture has been upgraded to support **multiple protocol adapters** while preserving the core Memory OS functionality.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                              │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
│ GitHub      │ Terminal/   │ Generic IDE │ LangChain/  │ curl/   │
│ Copilot CLI │ Bash        │ Plugin      │ AutoGPT     │ HTTP    │
└──────┬──────┴──────┬──────┴──────┬──────┴──────┬──────┴────┬────┘
       │             │             │             │            │
       │ stdio       │ subprocess  │ HTTP        │ HTTPS      │ HTTP
       ▼             ▼             ▼             ▼            ▼
┌─────────────────────────────────────────────────────────────────┐
│              Universal Aperture: Protocol Adapters               │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ MCP Adapter │ CLI Adapter │ HTTP/REST   │ OpenAI Adapter        │
│ (stdio)     │ (Go binary) │ (Phoenix)   │ (/v1/chat/completions)│
└──────┬──────┴──────┬──────┴──────┬──────┴───────────┬───────────┘
       │             │             │                   │
       └─────────────┴─────────────┴───────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Core: Mimo Memory OS                          │
├─────────────────────────────────────────────────────────────────┤
│  Port: QueryInterface          Port: ToolInterface              │
│  (ask/3)                       (execute/2)                      │
├─────────────────────────────────────────────────────────────────┤
│                   Meta-Cognitive Router                          │
│                   (classify → route)                             │
├─────────────┬─────────────────────────┬─────────────────────────┤
│ Episodic    │ Semantic Store          │ Procedural Store        │
│ Store       │ (Graph/JSON-LD)         │ (Rule Engine)           │
│ (Vector/PG) │ [Pending]               │ [Pending]               │
└─────────────┴─────────────────────────┴─────────────────────────┘
```

---

## What's New in v2.2.0

### 1. Port Interfaces (Hexagonal Architecture)
- `Mimo.QueryInterface` - Abstract port for natural language queries
- `Mimo.ToolInterface` - Abstract port for direct tool execution
- `Mimo.MetaCognitiveRouter` - Intelligent query classification

### 2. HTTP/REST Gateway (Phoenix)
- **POST /v1/mimo/ask** - Natural language queries
- **POST /v1/mimo/tool** - Direct tool execution
- **GET /v1/mimo/tools** - List available tools
- **GET /health** - Health check endpoint

### 3. OpenAI-Compatible Endpoint
- **POST /v1/chat/completions** - Drop-in OpenAI replacement
- **GET /v1/models** - List available models
- Returns `tool_calls` to force memory function invocation
- Compatible with LangChain, AutoGPT, Continue.dev

### 4. CLI Wrapper (`mimo`)
- Go binary for shell-native access
- Supports Unix pipes: `git diff | mimo ask "commit message"`
- Sandbox mode for untrusted scripts

### 5. Telemetry & Metrics
- Request latency tracking
- Router classification timing
- System health monitoring
- p99 latency alerts

---

## File Structure

```
lib/
├── mimo.ex                          # Main module
├── mimo_web.ex                      # Phoenix web helpers
├── mimo/
│   ├── application.ex               # OTP application (updated)
│   ├── meta_cognitive_router.ex     # Query classification (NEW)
│   ├── telemetry.ex                 # Metrics (NEW)
│   ├── mcp_server.ex                # MCP stdio adapter
│   ├── mcp_cli.ex                   # CLI MCP handler
│   ├── registry.ex                  # Tool registry
│   ├── repo.ex                      # Ecto repo
│   ├── brain/                       # Memory stores
│   │   ├── memory.ex
│   │   ├── llm.ex
│   │   └── engram.ex
│   ├── ports/                       # Abstract ports (NEW)
│   │   ├── query_interface.ex
│   │   └── tool_interface.ex
│   └── skills/
│       ├── catalog.ex
│       └── client.ex
├── mimo_web/                        # Phoenix HTTP adapter (NEW)
│   ├── endpoint.ex
│   ├── router.ex
│   ├── error_json.ex
│   ├── controllers/
│   │   ├── ask_controller.ex
│   │   ├── tool_controller.ex
│   │   ├── openai_controller.ex
│   │   ├── health_controller.ex
│   │   └── fallback_controller.ex
│   └── plugs/
│       ├── authentication.ex
│       ├── telemetry.ex
│       └── latency_guard.ex
cmd/
└── mimo/                            # Go CLI (NEW)
    ├── main.go
    ├── go.mod
    └── README.md
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MIMO_HTTP_PORT` | 4000 | HTTP gateway port |
| `MIMO_API_KEY` | (none) | API key for auth (optional in dev) |
| `MIMO_SECRET_KEY_BASE` | (dev key) | Phoenix secret key |
| `MCP_PORT` | 9000 | MCP server port |
| `OPENROUTER_API_KEY` | (none) | OpenRouter API key |
| `OLLAMA_URL` | localhost:11434 | Ollama embedding server |

### Starting the Server

```bash
# Development
mix deps.get
mix ecto.setup
mix run --no-halt

# Production
MIX_ENV=prod mix release
_build/prod/rel/mimo_mcp/bin/mimo_mcp start

# Docker
docker-compose up -d
```

### Testing the HTTP API

```bash
# Health check
curl http://localhost:4000/health

# Ask endpoint
curl -X POST http://localhost:4000/v1/mimo/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "How do I center a div?"}'

# Tool endpoint
curl -X POST http://localhost:4000/v1/mimo/tool \
  -H "Content-Type: application/json" \
  -d '{"tool": "search_vibes", "arguments": {"query": "dark atmosphere", "limit": 5}}'

# OpenAI-compatible
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mimo-polymorphic-1",
    "messages": [{"role": "user", "content": "Find authentication bugs"}]
  }'
```

---

## Previous Issue: MCP Stdio Hanging

The original MCP stdio transport had issues with VS Code's pipelined requests. The Universal Aperture architecture **bypasses this** by providing HTTP as an alternative transport.

### Solution for VS Code
Instead of stdio over SSH, use the HTTP endpoint:
1. Start Mimo with HTTP gateway
2. Configure VS Code to use HTTP transport (via custom extension or REST client)
3. Or use the `mimo` CLI from terminal

---

## Next Steps

1. **Semantic Store**: Implement graph/JSON-LD storage
2. **Procedural Store**: Implement rule engine
3. **Rust NIFs**: Add Rustler for vector math performance
4. **Docker**: Update image for HTTP gateway
5. **Benchmarks**: Run `wrk` tests for latency targets

---

## Quick Commands

```bash
# Start server
mix run --no-halt

# Build CLI
cd cmd/mimo && go build -o mimo .

# Test CLI
./mimo ask "What is the capital of France?"
./mimo run search_vibes --query "mysterious" --limit 3

# Deploy to VPS
git push origin main
ssh root@172.18.0.1 "cd /root/mrc-server/mimo-mcp && git pull && mix deps.get && mix compile"
```

---

## GitHub Repo
https://github.com/pudingtabi/mimo-mcp
