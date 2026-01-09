# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mimo is a memory system for AI agents, implemented as an MCP (Model Context Protocol) server in Elixir. It provides persistent memory, knowledge graphs, and tools for file/terminal/web operations. The system runs as an MCP server over stdio for integration with Claude Desktop, VS Code, or other MCP clients.

## Core Tools (12 Consolidated)

After Phase 0-3 consolidation, Mimo exposes 12 core tools:

| Tool | Purpose | Key Operations |
|------|---------|----------------|
| `memory` | Persistent semantic memory | store, search, stats, synthesize, graph, ingest |
| `reason` | Structured reasoning | assess, gaps, thought, plan, guided, amplify_* |
| `code` | Code intelligence | symbols, definition, references, library_get, diagnose |
| `file` | File operations | read, write, edit, glob, search, diff |
| `terminal` | Shell execution | execute, start_process, list_sessions |
| `web` | Web operations | fetch, search, browser, screenshot, vision |
| `meta` | Composite operations | analyze_file, debug_error, prepare_context, suggest_next_tool |
| `onboard` | Project initialization | Auto-index symbols, dependencies, knowledge |
| `autonomous` | Background task execution | queue, status, pause, resume |
| `orchestrate` | Multi-tool orchestration | execute, execute_plan, classify, run_procedure |
| `tool_usage` | Analytics | stats, detail |
| `awakening_status` | Agent progression | status, achievements |

### Consolidated Tool Routing

Legacy tools route to consolidated tools automatically:
- `knowledge` → `memory operation=graph`
- `ask_mimo` → `memory operation=synthesize`
- `cognitive` → `reason`
- `think` → `reason`
- `code_symbols` → `code`
- `library` → `code operation=library_*`
- `diagnostics` → `code operation=diagnose`

## Mimo Workflow Patterns

**The Core Principle: REASON → CONTEXT → INTELLIGENCE → ACTION → LEARN**

### Session Start
Always begin with context gathering:
```
memory operation=synthesize query="What context do you have about this project?"
onboard path="."  # For new/unknown projects
```

### Before Reading Files
Check memory first - you may already know what you need:
```
memory operation=search query="[topic]"
→ Found context? Use it, may skip file read
→ No context? Now read with purpose
```

### Tool Selection Quick Reference

| Task | Wrong Tool | Right Tool |
|------|------------|------------|
| Find function definition | `file search` | `code operation=definition name="fn"` |
| Find all usages | `grep` | `code operation=references name="Class"` |
| Package documentation | `web search` | `code operation=library_get name="pkg"` |
| Check for errors | `terminal compile` | `code operation=diagnose path="."` |
| Understand relationships | `file search` | `memory operation=graph query="..."` |
| Before reading a file | immediately read | `memory operation=search` first |
| Complex decisions | just answer | `reason operation=guided` first |
| Need deep thinking | quick response | `reason operation=amplify_start` |
| Multi-step automation | manual steps | `orchestrate operation=execute` |

### After Every Discovery
Store findings for future sessions:
```
memory operation=store content="[insight]" category=fact importance=0.7
```

### Debugging Workflow
1. `memory operation=search query="similar error [error text]"` - Check past fixes
2. `code operation=diagnose path="."` - Get structured errors
3. `code operation=definition name="[failing function]"` - Find source
4. Fix the issue
5. `memory operation=store content="Fixed: [solution]" category=action importance=0.8`

### Target Tool Distribution

| Phase | Tools | Target % |
|-------|-------|----------|
| Context | memory (search/synthesize/graph) | 15-20% |
| Intelligence | code (symbols/library/diagnose) | 15-20% |
| Action | file, terminal | 45-55% |
| Learning | memory (store) | 10-15% |
| Reasoning | reason (guided/amplify) | 5-10% |

## Common Commands

```bash
# Setup
mix deps.get
mix ecto.create && mix ecto.migrate

# Run MCP server (stdio mode for Claude Desktop)
./bin/mimo-mcp-stdio

# Run with Bun wrapper (faster startup)
bun bin/mimo-bun-wrapper.js

# Development
mix compile                    # Compile the project
mix test                       # Run all tests (excludes :integration, :external, :hnsw_nif by default)
mix test test/path/to_test.exs # Run a specific test file
mix test --only integration    # Run integration tests
mix credo                      # Run linter
mix dialyzer                   # Run type checker

# Database
mix ecto.migrate               # Run migrations
mix ecto.reset                 # Drop, create, and migrate (alias: mix reset)

# Useful aliases
mix setup                      # deps.get + ecto.create + ecto.migrate
```

## Architecture

### Entry Points

- **`Mimo.Application`** (`lib/mimo/application.ex`) - OTP supervision tree entry point. Starts ~50+ GenServers for memory, cognitive, and tool systems.
- **`Mimo.McpServer.Stdio`** (`lib/mimo/mcp_server/stdio.ex`) - JSON-RPC 2.0 over stdio, the main interface for MCP clients.
- **`MimoWeb.Endpoint`** - Phoenix HTTP endpoint for REST/OpenAI API access (disabled in stdio mode).

### Tool System

- **`Mimo.Tools`** (`lib/mimo/tools.ex`) - Facade module that dispatches tool calls to specialized dispatchers.
- **`Mimo.Tools.Dispatchers.*`** - Per-tool dispatcher modules (File, Terminal, Web, Code, etc.).
- **`Mimo.Tools.Definitions`** - MCP tool JSON schemas.
- **`Mimo.ToolRegistry`** - Tool classification and routing.

### Memory System (Brain)

Core memory is stored in SQLite via Ecto. Key modules:

- **`Mimo.Brain.Engram`** (`lib/mimo/brain/engram.ex`) - The polymorphic memory unit. Stores content, category, importance, embeddings (float32/int8/binary), and decay metadata.
- **`Mimo.Brain.WorkingMemory`** - ETS-backed short-term memory with TTL.
- **`Mimo.Brain.Consolidator`** - Transfers working memory to long-term (engrams).
- **`Mimo.Brain.Forgetting`** - Decay-based memory cleanup.
- **`Mimo.Brain.HybridScorer`** - Combines vector similarity, recency, access frequency, and importance.

Memory categories: `fact`, `observation`, `action`, `plan`, `episode`, `procedure`, `entity_anchor`.

### Knowledge Graph (Synapse)

- **`Mimo.Synapse.*`** - Graph nodes and edges for relationships.
- **`Mimo.SemanticStore`** - Triple-based knowledge (subject, predicate, object).
- **`Mimo.Knowledge.InjectionMiddleware`** - Proactively injects relevant knowledge into tool responses.

### Cognitive Systems

- **`Mimo.Cognitive.ReasoningSession`** - Multi-step reasoning with strategy selection (CoT, ToT, ReAct, Reflexion).
- **`Mimo.Cognitive.Amplifier`** - Cognitive amplification that forces deeper thinking.
- **`Mimo.Brain.Reflector.*`** - Self-reflection and confidence calibration.
- **`Mimo.Brain.Emergence.*`** - Pattern detection and promotion.
- **`Mimo.ActiveInference`** - Proactive context pushing.

### Cognitive Amplifier

The Cognitive Amplifier (`lib/mimo/cognitive/amplifier/`) forces deeper, more rigorous thinking:

**Usage via reason tool:**
```
reason operation=amplify_start problem="..." level="standard"
reason operation=amplify_think session_id=... thought="..."
reason operation=amplify_challenge session_id=... challenge_id=... response="..."
reason operation=amplify_conclude session_id=...
```

**Amplification Levels:**
- `:minimal` - Pass-through, no forcing
- `:standard` - Decomposition + 2 challenges, 2 perspectives (recommended for most cases)
- `:deep` - Full pipeline with 4 challenges, 3 perspectives, coherence validation
- `:exhaustive` - Maximum amplification (use sparingly)
- `:adaptive` - Auto-select based on problem complexity

### Automatic Deeper Thinking

**IMPORTANT: For complex questions, USE MIMO REASONING BEFORE RESPONDING.**

When facing these types of questions, invoke the reason tool FIRST:
- Architectural decisions or design questions
- Debugging complex issues
- Analysis or evaluation requests
- Multi-step planning
- Questions where you feel uncertain

**Before responding to complex questions:**
```
reason operation=guided problem="[the user's question]" strategy=auto
```

Then follow the reasoning steps before formulating your response.

### Feature Flags

Feature flags in `config/config.exs` control optional modules:
- `rust_nifs` - SIMD vector operations (requires compilation)
- `hnsw_index` - O(log n) vector search
- `semantic_store` - Triple-based knowledge graph
- `procedural_store` - State machine execution
- `websocket_synapse` - Real-time signaling

### Configuration

- **`config/config.exs`** - Main configuration for memory, decay, retrieval, and features.
- **`config/dev.exs`** / **`config/test.exs`** / **`config/prod.exs`** - Environment-specific overrides.

Environment variables:
- `MIMO_ROOT` - Workspace root for file operations (default: current directory)
- `OLLAMA_URL` - Embedding server (default: http://localhost:11434)
- `CEREBRAS_API_KEY` or `OPENROUTER_API_KEY` - LLM API access (required)

### Database Schema

SQLite database with key tables:
- `engrams` - Memory storage with embeddings
- `graph_nodes` / `graph_edges` - Knowledge graph
- `semantic_triples` - Subject-predicate-object facts
- `code_symbols` / `symbol_references` - Code intelligence
- `threads` / `interactions` - Session tracking

## Testing

Tests use Ecto SQL Sandbox for isolation. Support files in `test/support/`:
- `DataCase` - Database test case with sandbox
- `ChannelCase` - WebSocket channel testing

Run specific test:
```bash
mix test test/mimo/brain/engram_test.exs
mix test test/mimo/brain/engram_test.exs:42  # Specific line
```

## Key Patterns

### Decay Scoring
Memories decay based on importance (SPEC-003). Higher importance = lower decay rate = longer retention.

### Hybrid Retrieval
Memory search combines: vector similarity (35%), recency (25%), access frequency (15%), importance (15%), graph connectivity (10%).

### Temporal Memory Chains (SPEC-034)
Memories can supersede each other (`supersedes_id`), maintaining version history while excluding old versions from default searches.

### Graceful Degradation
If critical services fail, `start_minimal_supervisor/0` launches a degraded mode with core functionality.
