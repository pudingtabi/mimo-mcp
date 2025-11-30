# Mimo-MCP Copilot Instructions

Mimo is a **Memory Operating System** for AI agents—an Elixir/Phoenix MCP server with persistent memory, semantic knowledge graphs, and tool orchestration.

## Architecture Overview

```
Clients (Claude/VS Code/HTTP) → Protocol Adapters → MetaCognitiveRouter
                                                          ↓
                              ┌─────────────────────────────┴─────────────────────────────┐
                              ↓                             ↓                             ↓
                         ToolRegistry              Memory Stores                   Synapse Graph
                        (Mimo.Tools)         (Brain/Semantic/Procedural)        (Graph RAG)
```

**Key components:**
- `Mimo.Tools` - 12 consolidated native tools (file, terminal, fetch, etc.) with operation-based dispatch
- `Mimo.Brain` - Cognitive memory: working memory (ETS), episodic (SQLite+vectors), consolidation, decay
- `Mimo.SemanticStore` - Triple-based knowledge graph with inference engine
- `Mimo.ProceduralStore` - FSM execution for deterministic workflows
- `Mimo.Synapse` - Graph RAG with typed nodes/edges and hybrid query (SPEC-023)

## Project Conventions

### Module Organization
- Main modules: `lib/mimo/<feature>.ex` (facade)
- Sub-modules: `lib/mimo/<feature>/<component>.ex`
- Skills (tools): `lib/mimo/skills/<skill>.ex`
- Tests mirror `lib/` structure under `test/mimo/`

### Tool Pattern (Mimo.Tools)
Tools use operation-based dispatch. Add new operations by:
1. Add to `@tool_definitions` in [lib/mimo/tools.ex](lib/mimo/tools.ex)
2. Add dispatcher function `dispatch_<tool>(args)`
3. Implementation in `lib/mimo/skills/<skill>.ex`

```elixir
# Example: Adding operation to existing tool
defp dispatch_file(%{"operation" => "new_op"} = args) do
  Mimo.Skills.FileOps.new_op(args["path"], args["content"])
end
```

### Database Schema
- SQLite via Ecto (`Mimo.Repo`)
- Migrations in `priv/repo/migrations/`
- Schemas: `Mimo.Brain.Engram`, `Mimo.SemanticStore.Triple`, `Mimo.Synapse.GraphNode/GraphEdge`

### Error Handling Pattern
```elixir
# Return tuples, pattern match at call site
{:ok, result} | {:error, reason}

# Use RetryStrategies for transient failures
Mimo.ErrorHandling.RetryStrategies.with_retry(fn -> operation() end)
```

### Feature Flags
Enable modules via config or env vars:
```elixir
# config/config.exs
config :mimo_mcp, :feature_flags,
  rust_nifs: true,
  semantic_store: true,
  websocket_synapse: true
```

## Development Workflows

### Setup & Run
```bash
mix deps.get && mix ecto.create && mix ecto.migrate
./bin/mimo server          # HTTP server on :4000
./bin/mimo stdio           # MCP stdio mode
```

### Testing
```bash
mix test                            # Run all tests (652+)
mix test test/mimo/synapse/         # Test specific module
mix test --trace                    # Verbose output
MIX_ENV=test mix ecto.migrate       # Migrate test DB
```

Test setup uses `Mimo.DataCase` for database tests:
```elixir
use Mimo.DataCase, async: true  # or async: false for serialized
```

### Key Environment Variables
| Variable | Purpose |
|----------|---------|
| `MIMO_ROOT` | Sandbox root for file operations |
| `MIMO_API_KEY` | API authentication |
| `OLLAMA_URL` | Embeddings server (default: http://localhost:11434) |
| `OPENROUTER_API_KEY` | Vision/AI features |

## Code Patterns to Follow

### Adding a New MCP Tool
1. Define in `@tool_definitions` with JSON Schema
2. Add dispatcher clause with operation matching
3. Implement in appropriate skills module
4. Add tests in `test/mimo/<module>_test.exs`

### Memory Operations
```elixir
# Store
Mimo.Brain.Memory.store_memory("content", category: :fact, importance: 0.8)

# Search (returns with similarity scores)
Mimo.Brain.Memory.search_memories("query", limit: 10, min_similarity: 0.3)

# Working memory (ETS, auto-expires)
Mimo.Brain.WorkingMemory.store(content, importance: 0.7)
```

### Semantic Store (Knowledge Graph)
```elixir
# Create triple
Mimo.SemanticStore.Repository.create(%{
  subject_id: "auth_service", subject_type: "service",
  predicate: "depends_on",
  object_id: "user_service", object_type: "service"
})

# Query with inference
Mimo.SemanticStore.Query.transitive_closure("entity", "type", "predicate")
```

### Synapse Graph (SPEC-023)
```elixir
# Add typed node
Mimo.Synapse.Graph.add_node(%{type: :function, name: "login/2", properties: %{}})

# Traverse with BFS
Mimo.Synapse.Traversal.bfs(node_id, max_depth: 3, edge_types: [:calls, :imports])

# Hybrid query (vector + graph)
Mimo.Synapse.QueryEngine.query("authentication", hops: 2, types: [:function])
```

## Specs & Documentation
- Implementation specs: `docs/specs/SPEC-*.md`
- Agent prompts: `docs/specs/prompts/`
- Feature status: Check `README.md` Feature Status Matrix

## Common Gotchas
- Use `Mimo.DataCase` not `ExUnit.Case` for DB tests
- File ops sandboxed to `MIMO_ROOT` - use absolute paths
- Embeddings require Ollama running (`ollama pull qwen3-embedding:0.6b`)
- MCP stdio mode needs `LOGGER_LEVEL=none` for clean output
