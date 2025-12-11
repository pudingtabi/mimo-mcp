# Mimo

**Give your AI agents a brain that remembers.**

Mimo is a Memory Operating System for AI agents. It provides persistent memory, knowledge graphs, and 19 unified tools — so your AI actually learns from conversations and remembers context across sessions.

[![Elixir](https://img.shields.io/badge/Elixir-1.19+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/Tests-1000+-green.svg)]()

---

## Why Mimo?

| Without Mimo | With Mimo |
|--------------|-----------|
| AI forgets everything between sessions | Memories persist forever (with intelligent decay) |
| No context about your project | Remembers your codebase, preferences, patterns |
| Generic responses | Context-aware responses using past interactions |
| Manual tool setup | 17 built-in tools ready to use |

---

## Quick Start (2 minutes)

### Option 1: Docker (Recommended)

```bash
git clone https://github.com/yourusername/mimo-mcp.git
cd mimo-mcp
docker-compose up -d
docker exec mimo-ollama ollama pull qwen3-embedding:0.6b
curl http://localhost:4000/health  # Should return {"status":"healthy"}
```

### Option 2: Single Binary

Download from [Releases](https://github.com/yourusername/mimo-mcp/releases), then:

```bash
./mimo server  # HTTP server on port 4000
./mimo stdio   # MCP mode for Claude/VS Code
```

---

## Connect to Your AI

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (Mac) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/path/to/mimo-mcp/bin/mimo",
      "args": ["stdio"],
      "env": {
        "MIMO_ROOT": "/path/to/your/workspace"
      }
    }
  }
}
```

### VS Code Copilot

Add to `~/.vscode/mcp.json`:

```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "/path/to/mimo-mcp/bin/mimo",
      "args": ["stdio"],
      "env": {
        "MIMO_ROOT": "/path/to/your/workspace"
      }
    }
  }
}
```

---

## Key Features

| Feature | What It Does |
|---------|--------------|
| **Persistent Memory** | Stores facts, observations, and actions across sessions |
| **Semantic Search** | Find memories by meaning, not just keywords |
| **Knowledge Graph** | Store relationships between entities (A depends on B) |
| **17 Native Tools** | File ops, terminal, web search, code analysis, and more |
| **Memory Decay** | Old, unimportant memories fade naturally |
| **HNSW Index** | O(log n) search for large memory stores (v2.6) |
| **Binary Quantization** | 32x memory reduction with fast Hamming search (v2.6) |
| **Temporal Memory Chains** | Version history and memory evolution tracking (v2.6) |
| **Multi-Protocol** | HTTP API, MCP stdio, WebSocket — your choice |

---

## Core Tools

Mimo exposes 19 unified tools via MCP (with deprecated aliases hidden but working for backward compatibility). Here are the most used:

| Tool | Example | Purpose |
|------|---------|---------|
| `memory` | `memory operation=store content="User likes TypeScript"` | Store/search memories |
| `file` | `file operation=edit path="app.ts" old_str="x" new_str="y"` | Read, write, edit files |
| `terminal` | `terminal command="npm test"` | Run shell commands |
| `web` | `web operation=search query="React hooks best practices"` | All web/network operations |
| `code` | `code operation=symbols path="src/"` | Code symbols, library docs, diagnostics |
| `knowledge` | `knowledge operation=teach text="Auth depends on DB"` | Build knowledge graph |
| `cognitive` | `cognitive operation=assess topic="decision"` | Meta-cognition & verification |
| `meta` | `meta operation=prepare_context query="task"` | Composite operations |
| `onboard` | `onboard path="."` | Index project at session start |

See [full tool reference →](docs/API_REFERENCE.md)

---

## How Memory Works

```
You say something → Mimo stores it → Time passes → You ask about it → Mimo remembers

┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Working Memory  │ ──► │ Episodic Store  │ ──► │ Long-term with  │
│ (5 min buffer)  │     │ (SQLite+Vector) │     │ decay scoring   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**Memory categories:**
- `fact` — Technical truths ("Project uses PostgreSQL")
- `observation` — User patterns ("Prefers functional style")
- `action` — What happened ("Deployed v2.0")
- `plan` — Future intentions ("Need to refactor auth")

**Importance scores (0-1):** Higher = remembered longer
- `0.9` — Critical constraints, security requirements
- `0.7` — Key decisions, user preferences  
- `0.5` — General facts (default)
- `0.3` — Temporary context

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MIMO_ROOT` | `.` | Workspace root for file operations |
| `MIMO_API_KEY` | none | Protect HTTP endpoints |
| `OLLAMA_URL` | `http://localhost:11434` | Embedding model server |
| `OPENROUTER_API_KEY` | none | Enable vision/image analysis |

---

## Documentation

| Doc | Description |
|-----|-------------|
| [API Reference](docs/API_REFERENCE.md) | All endpoints and tools |
| [Architecture](docs/ARCHITECTURE.md) | System design and roadmap |
| [Deployment Guide](docs/DEPLOYMENT.md) | Docker, VPS, native setup |
| [Agent Integration Guide](AGENTS.md) | How AI agents should use Mimo |
| [Security Policy](SECURITY.md) | Security best practices and guidelines |
| [Specifications](docs/specs/README.md) | Core implementation specs (SPEC-001 to SPEC-011) |
| [Vision](VISION.md) | Long-term roadmap |

---

## Development

```bash
# Setup
mix deps.get
mix ecto.create && mix ecto.migrate

# Run
./bin/mimo server    # HTTP on :4000
./bin/mimo stdio     # MCP mode

# Test
mix test             # 1000+ tests
```

---

## Known Limitations

- Ollama required for embeddings (falls back to hashing if unavailable)
- HNSW index uses ~1GB RAM for 1M vectors (auto-disabled in CI)
- Vision tool requires `OPENROUTER_API_KEY`
- Single-node tested; distributed mode is experimental

---

## License

MIT — see [LICENSE](LICENSE)

---

**Mimo: Where Agents Remember.**
