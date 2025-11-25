# Mimo-MCP Gateway v2.1

A universal MCP (Model Context Protocol) gateway that aggregates multiple MCP servers into a single interface, powered by hybrid AI intelligence (OpenRouter + Ollama).

[![Elixir](https://img.shields.io/badge/Elixir-1.16+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is Mimo?

Mimo is an **intelligent MCP aggregator** that:
- 🔗 Combines multiple MCP tool servers into one unified interface
- 🧠 Adds AI-powered memory and reasoning on top
- 💾 Stores episodic memories in SQLite with vector embeddings
- 🔄 Hot-reloads external skills without restart
- 🛡️ Gracefully degrades when services are unavailable

---

## Installation

### Option 1: Quick Install (Recommended)

```bash
# Clone the repository
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Install Elixir dependencies
mix deps.get

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Run the server
mix run --no-halt
```

### Option 2: Docker Install

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp

# Build and run with Docker Compose
docker-compose up -d

# Check it's running
docker logs -f mimo-mcp
```

### Option 3: One-Line Install (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/pudingtabi/mimo-mcp/main/install.sh | bash
```

---

## Prerequisites

### Required
| Software | Version | Installation |
|----------|---------|--------------|
| Elixir | 1.16+ | `brew install elixir` or [asdf](https://asdf-vm.com/) |
| Erlang/OTP | 26+ | Installed with Elixir |

### Optional (but recommended)
| Software | Purpose | Installation |
|----------|---------|--------------|
| Node.js | External MCP skills | `brew install node` |
| Ollama | Local embeddings | [ollama.com](https://ollama.com/) |
| OpenRouter API | AI reasoning | [openrouter.ai](https://openrouter.ai/) |

### Installing Elixir

**macOS:**
```bash
brew install elixir
```

**Ubuntu/Debian:**
```bash
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install esl-erlang elixir
```

**Using asdf (recommended for version management):**
```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 26.2
asdf install elixir 1.16.0-otp-26
asdf global erlang 26.2
asdf global elixir 1.16.0-otp-26
```

---

## Configuration

### 1. Environment Variables

Copy the example config:
```bash
cp .env.example .env
```

Edit `.env` with your keys:
```bash
# Required for AI reasoning (get free key at openrouter.ai)
OPENROUTER_API_KEY=sk-or-v1-xxxxx

# Optional: GitHub integration
GITHUB_TOKEN=ghp_xxxxx

# Optional: Custom Ollama URL (default: localhost:11434)
OLLAMA_URL=http://localhost:11434
```

### 2. Verify Installation

```bash
./verify.sh
```

Expected output:
```
✓ Elixir version OK
✓ Dependencies installed
✓ Database migrated
✓ Configuration valid
Ready to run!
```

---

## Usage

### Running the Server

```bash
# Development mode (with logs)
mix run --no-halt

# Production mode
MIX_ENV=prod mix run --no-halt

# With specific port
MCP_PORT=9001 mix run --no-halt
```

### VS Code Integration

Add to your VS Code `settings.json`:

```json
{
  "mcp.servers": {
    "mimo": {
      "command": "mix",
      "args": ["run", "--no-halt"],
      "cwd": "/path/to/mimo-mcp",
      "env": {
        "OPENROUTER_API_KEY": "your-key-here"
      }
    }
  }
}
```

### Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mimo": {
      "command": "mix",
      "args": ["run", "--no-halt"],
      "cwd": "/path/to/mimo-mcp",
      "env": {
        "OPENROUTER_API_KEY": "your-key-here"
      }
    }
  }
}
```

---

## Docker Deployment

### Using Docker Compose (recommended)

```bash
# Start all services (Mimo + Ollama)
docker-compose up -d

# Pull embedding model
docker exec mimo-ollama ollama pull nomic-embed-text

# Check logs
docker logs -f mimo-mcp

# Stop
docker-compose down
```

### Using Docker directly

```bash
# Build image
docker build -t mimo-mcp .

# Run container
docker run -d \
  --name mimo-mcp \
  -e OPENROUTER_API_KEY=your-key \
  -v mimo-data:/app/priv \
  mimo-mcp
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Mimo.Application                          │
│                      (Supervisor)                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Mimo.Repo   │  │  Registry   │  │  TaskSupervisor     │  │
│  │  (SQLite)   │  │   (ETS)     │  │                     │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              Mimo.Skills.Supervisor                      ││
│  │               (DynamicSupervisor)                        ││
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐                    ││
│  │  │ GitHub  │ │  File   │ │ Custom  │  ...               ││
│  │  │ Client  │ │ Client  │ │ Client  │                    ││
│  │  └─────────┘ └─────────┘ └─────────┘                    ││
│  └─────────────────────────────────────────────────────────┘│
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                  Mimo.McpServer                          ││
│  │            (JSON-RPC 2.0 over stdio)                     ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## Available Tools

### Built-in Tools

| Tool | Description |
|------|-------------|
| `ask_mimo` | Query AI memory for strategic guidance |
| `mimo_store_memory` | Store observations/facts for future recall |
| `mimo_reload_skills` | Hot-reload external MCP skills |

### External Skills (via priv/skills.json)

Configure any MCP-compatible server as a skill:

```json
{
  "filesystem": {
    "command": "npx",
    "args": ["-y", "@anthropic/mcp-filesystem"],
    "env": {}
  },
  "github": {
    "command": "npx", 
    "args": ["-y", "@anthropic/mcp-github"],
    "env": {
      "GITHUB_TOKEN": "${GITHUB_TOKEN}"
    }
  }
}
```

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENROUTER_API_KEY` | No | - | AI reasoning via Grok |
| `OLLAMA_URL` | No | localhost:11434 | Local embeddings |
| `GITHUB_TOKEN` | No | - | GitHub skill auth |
| `MCP_PORT` | No | 9000 | Server port |
| `DB_PATH` | No | priv/mimo_mcp.db | SQLite path |

---

## Troubleshooting

### "mix: command not found"
Elixir is not installed. See [Prerequisites](#prerequisites).

### "could not compile dependency"
```bash
mix deps.clean --all
mix deps.get
mix deps.compile
```

### "Ollama unavailable"
This is OK! Mimo uses hash-based fallback embeddings. For better results:
```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull embedding model
ollama pull nomic-embed-text
```

### "OpenRouter API error"
Get a free API key at [openrouter.ai](https://openrouter.ai/). Without it, Mimo still works but without AI reasoning.

### Skills not loading
1. Check `priv/skills.json` is valid JSON
2. Ensure Node.js is installed: `node --version`
3. Check stderr output for errors

---

## Development

```bash
# Run tests
mix test

# Format code
mix format

# Static analysis
mix credo
```

---

## License

MIT License - see [LICENSE](LICENSE)

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `mix test`
5. Submit a pull request

---

Built with ❤️ using Elixir/OTP
