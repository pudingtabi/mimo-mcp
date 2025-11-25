# Mimo-MCP Gateway v2.1

A universal MCP (Model Context Protocol) gateway that aggregates multiple MCP servers into a single unified interface, powered by hybrid AI intelligence (OpenRouter + Ollama).

[![Elixir](https://img.shields.io/badge/Elixir-1.16+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is Mimo?

Mimo is an **intelligent MCP aggregator** that:
- 🔗 Combines multiple MCP tool servers into one unified interface
- 🧠 Adds AI-powered memory and reasoning on top
- 💾 Stores episodic memories in SQLite with vector embeddings
- 🔄 Hot-reloads external skills without restart
- 🛡️ Gracefully degrades when services are unavailable
- 🎯 **Single MCP server = all your tools** (no config sprawl)

---

## Quick Start

### VS Code (Global Setup)

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

### Docker Deployment (VPS)

```bash
# Clone and deploy
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp
docker-compose up -d

# Pull embedding model
docker exec mimo-ollama ollama pull nomic-embed-text

# Create stdio wrapper
cat > /usr/local/bin/mimo-mcp-stdio << 'EOF'
#!/bin/bash
exec docker exec -i -e LOGGER_LEVEL=none mimo-mcp mix run --no-halt 2>/dev/null | sed -un '/^{/p'
EOF
chmod +x /usr/local/bin/mimo-mcp-stdio
```

---

## Current Tool Stack (46 tools)

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
  },
  "playwright": {
    "command": "npx",
    "args": ["-y", "@playwright/mcp@latest"],
    "env": {}
  }
}
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       VS Code                                │
│                    (MCP Client)                              │
└───────────────────────┬─────────────────────────────────────┘
                        │ SSH tunnel
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    VPS Host                                  │
│              /usr/local/bin/mimo-mcp-stdio                   │
│                  (JSON filter wrapper)                       │
└───────────────────────┬─────────────────────────────────────┘
                        │ docker exec
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                  mimo-mcp container                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Mimo.Repo   │  │  Registry   │  │  Skills.Supervisor  │  │
│  │  (SQLite)   │  │   (ETS)     │  │  (DynamicSupervisor)│  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                  Mimo.McpServer                          ││
│  │            (JSON-RPC 2.0 over stdio)                     ││
│  │                                                          ││
│  │  Built-in: ask_mimo, store_memory, reload_skills         ││
│  │  Skills: filesystem, fetch, playwright, exa, thinking    ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                  mimo-ollama container                       │
│                  (nomic-embed-text)                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Installation

### Option 1: Docker (Recommended for VPS)

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp
docker-compose up -d
```

### Option 2: Local Development

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Install dependencies
mix deps.get
mix ecto.create
mix ecto.migrate

# Run
mix run --no-halt
```

### Prerequisites

| Software | Version | Purpose |
|----------|---------|---------|
| Elixir | 1.16+ | Runtime |
| Node.js | 18+ | External MCP skills |
| Docker | 20+ | Container deployment |
| Ollama | Latest | Local embeddings (optional) |

---

## VS Code Integration

### Remote VPS Setup (Recommended)

If running VS Code via tunnel/remote on a VPS:

1. **Generate SSH key in VS Code container:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

2. **Add key to VPS host:**
```bash
# On VPS host (not in container)
echo "YOUR_PUBLIC_KEY" >> ~/.ssh/authorized_keys
```

3. **Create wrapper script on VPS host:**
```bash
cat > /usr/local/bin/mimo-mcp-stdio << 'EOF'
#!/bin/bash
exec docker exec -i mimo-mcp mix run -e "Mimo.McpCli.run()" 2>/dev/null | grep "^{"
EOF
chmod +x /usr/local/bin/mimo-mcp-stdio
```

4. **Configure VS Code** (`~/.vscode/mcp.json`):
```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "ssh",
      "args": [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "root@172.18.0.1",
        "/usr/local/bin/mimo-mcp-stdio"
      ]
    }
  }
}
```

### Local Setup

```json
{
  "servers": {
    "mimo": {
      "type": "stdio",
      "command": "mix",
      "args": ["run", "--no-halt"],
      "cwd": "/path/to/mimo-mcp"
    }
  }
}
```

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENROUTER_API_KEY` | No | - | AI reasoning |
| `OLLAMA_URL` | No | localhost:11434 | Embeddings |
| `EXA_API_KEY` | No | - | Web search |
| `GITHUB_TOKEN` | No | - | GitHub skill |
| `MCP_PORT` | No | 9000 | Server port |
| `LOGGER_LEVEL` | No | info | Set to `none` for stdio |

---

## Troubleshooting

### VS Code only shows 3 tools
This issue has been **fixed**. The catalog now loads tools from a pre-generated manifest (`priv/skills_manifest.json`) instantly on startup. If you still see only 3 tools:
1. Ensure VPS has latest code: `cd /root/mrc-server/mimo-mcp && git pull`
2. Rebuild container: `docker-compose down && docker-compose build --no-cache && docker-compose up -d`
3. Update wrapper script (see below)
4. Reload VS Code window

### Wrapper script on VPS host
```bash
cat > /usr/local/bin/mimo-mcp-stdio << 'EOF'
#!/bin/bash
exec docker exec -i mimo-mcp mix run -e "Mimo.McpCli.run()" 2>/dev/null | grep "^{"
EOF
chmod +x /usr/local/bin/mimo-mcp-stdio
```

### SSH connection fails
```bash
# Test SSH from VS Code container
ssh -o BatchMode=yes root@172.18.0.1 "echo connected"
```

### Skills not loading
```bash
# Check container logs
docker logs mimo-mcp 2>&1 | grep -E "(✓|✗|error)"
```

### Ollama unavailable
Mimo works without Ollama (uses hash-based fallback). For better embeddings:
```bash
docker exec mimo-ollama ollama pull nomic-embed-text
```

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

- [ ] Native Elixir tools (no external MCP spawning)
- [ ] Persistent tool cache for instant discovery
- [ ] WebSocket transport option
- [ ] Multi-model reasoning (Claude, GPT-4, local)

---

## License

MIT License - see [LICENSE](LICENSE)

---

Built with ❤️ using Elixir/OTP
