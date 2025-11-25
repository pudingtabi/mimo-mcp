# Mimo-MCP Gateway v2.1 (Fixed Version)

A universal MCP gateway that aggregates multiple MCP servers into a single interface, powered by hybrid AI intelligence.

## Changes from v2.0

### Bug Fixes
- ✅ Added missing `import Ecto.Query` in memory module
- ✅ Added missing `require Logger` statements
- ✅ Fixed GenServer callback annotations (`@impl true`)
- ✅ Fixed environment variable interpolation
- ✅ Added fallback MCP server for compatibility

### Improvements
- ✅ Graceful fallback when OpenRouter API key not configured
- ✅ Fallback embeddings when Ollama unavailable
- ✅ Better error handling throughout
- ✅ Simplified dependency list (removed problematic deps)
- ✅ Multi-stage Docker build for smaller images

## Quick Start

### Prerequisites
- Elixir 1.16+ and Erlang/OTP 26+
- Node.js (for MCP skill servers)
- Optional: Ollama for local embeddings
- Optional: OpenRouter API key for AI reasoning

### Local Development

```bash
# Configure environment (optional)
cp .env.example .env
# Edit .env with your API keys

# Install dependencies and setup
mix setup

# Verify installation
./verify.sh

# Run the gateway
mix run --no-halt
```

### Docker Deployment

```bash
# Build and run
docker-compose up -d

# Check logs
docker logs -f mimo-mcp

# Pull Ollama models (if using local embeddings)
docker exec mimo-ollama ollama pull nomic-embed-text
```

## Architecture

```
Mimo.Application (Supervisor)
├── Mimo.Repo (Ecto/SQLite)
├── Mimo.Registry (ETS tool registry)
├── Mimo.TaskSupervisor
├── Mimo.Skills.Supervisor (DynamicSupervisor)
│   └── Mimo.Skills.Client (per external MCP server)
└── Mimo.McpServer (JSON-RPC stdio server)
```

## Available Tools

### Internal Tools
| Tool | Description |
|------|-------------|
| `ask_mimo` | Consult AI memory for strategic guidance |
| `mimo_store_memory` | Store new facts/observations |
| `mimo_reload_skills` | Hot-reload external skills |

### External Skills (configured in priv/skills.json)
- `filesystem_*` - File operations
- `github_*` - GitHub operations

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENROUTER_API_KEY` | No | - | For AI reasoning (Grok) |
| `OLLAMA_URL` | No | localhost:11434 | For local embeddings |
| `GITHUB_TOKEN` | No | - | For GitHub skill |
| `MCP_PORT` | No | 9000 | Server port |
| `DB_PATH` | No | priv/mimo_mcp.db | SQLite database path |

### Adding External Skills

Edit `priv/skills.json`:

```json
{
  "my_skill": {
    "command": "npx",
    "args": ["-y", "@some/mcp-server"],
    "env": {
      "API_KEY": "${MY_API_KEY}"
    }
  }
}
```

Then reload: use the `mimo_reload_skills` tool or restart.

## VS Code Integration

Add to your VS Code settings:

```json
{
  "mcp.servers": {
    "mimo": {
      "command": "mix",
      "args": ["run", "--no-halt"],
      "cwd": "/path/to/mimo_mcp",
      "env": {
        "OPENROUTER_API_KEY": "your-key-here"
      }
    }
  }
}
```

## Troubleshooting

### "hermes_mcp not found"
The system will use a fallback stdio-based MCP server. This is normal if the library isn't published on hex.pm.

### "Ollama unavailable"
Embeddings will use a simple hash-based fallback. For better results, install Ollama and pull `nomic-embed-text`.

### Skills not loading
1. Check `priv/skills.json` syntax
2. Ensure npx/node is installed
3. Check logs: `mix run --no-halt` (look at stderr)

## License

MIT License
