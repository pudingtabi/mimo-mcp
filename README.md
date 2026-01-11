# Mimo

**Memory for AI agents.**

Mimo is a memory system for AI agents. It stores memories, builds knowledge graphs, and provides tools for file/terminal/web operations — so your AI remembers context across sessions.

[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple.svg)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Documentation

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Tools vs Skills explained |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

---

## Quick Start

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+
- Ollama (for embeddings): `ollama pull nomic-embed-text`

### Setup

```bash
git clone https://github.com/pudingtabi/mimo-mcp.git
cd mimo-mcp
mix deps.get
mix ecto.create && mix ecto.migrate
```

### Run

```bash
# MCP mode (for Claude Desktop, VS Code, etc.)
./bin/mimo-mcp-stdio

# Or with Bun (faster startup)
bun bin/mimo-bun-wrapper.js
```

---

## Connect to Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (Mac):

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/path/to/mimo-mcp/bin/mimo-mcp-stdio",
      "env": {
        "MIMO_ROOT": "/path/to/your/workspace"
      }
    }
  }
}
```

---

## Tools

Mimo provides **14 unified tools** via MCP (consolidated from 36+):

| Tool | Purpose | Key Operations |
|------|---------|----------------|
| `memory` | Persistent memory + knowledge | store, search, synthesize, graph |
| `file` | File operations | read, write, edit, glob |
| `terminal` | Shell execution | execute, start_process |
| `web` | Web operations | fetch, search, browser, vision |
| `code` | Code intelligence | symbols, definition, library_get, diagnose |
| `reason` | Structured reasoning | guided, assess, plan, amplify |
| `cognitive` | Meta-cognition | assess, gaps, emergence_*, verify_* |
| `meta` | Composite operations | analyze_file, debug_error, prepare_context |
| `onboard` | Project initialization | indexes code, deps, knowledge |
| `autonomous` | Background tasks | queue, pause, resume |
| `orchestrate` | Multi-tool orchestration | execute, run_procedure |
| `awakening_status` | Agent progression | XP, achievements, power level |
| `tool_usage` | Analytics | stats, detail |

> **Architecture**: Tools are MCP interfaces. Skills are Elixir implementations.  
> See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete breakdown.

---

## Memory

Memories have categories and importance scores:

**Categories:**
- `fact` — Technical truths ("Project uses PostgreSQL")
- `observation` — Patterns ("User prefers TypeScript")
- `action` — Events ("Deployed v2.0")
- `plan` — Intentions ("Need to refactor auth")

**Importance (0-1):** Higher scores = remembered longer. Default is 0.5.

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MIMO_ROOT` | `.` | Workspace root for file operations |
| `OLLAMA_URL` | `http://localhost:11434` | Embedding server |
| `OPENROUTER_API_KEY` | — | For vision/LLM features |

---

## Development

```bash
mix deps.get
mix ecto.create && mix ecto.migrate
mix test
mix compile
```

---

## License

MIT — see [LICENSE](LICENSE)