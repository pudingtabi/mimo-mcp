# Mimo-MCP Copilot Instructions

Mimo is a **Memory Operating System** for AI agents—an Elixir/Phoenix MCP server with persistent memory, semantic knowledge graphs, and tool orchestration.

---

## 🚀 SMALL MODEL BOOST (Haiku/GPT-4-mini/etc.)

**If you are a smaller model**, use `prepare_context` as your FIRST tool for complex tasks:

```bash
# ONE CALL gets you Opus-level context!
prepare_context query="[describe your task]"
```

This aggregates memory + knowledge + code + library docs in parallel, giving you the context larger models have natively.

**When to use `prepare_context`:**
- Complex multi-step tasks
- Unfamiliar codebases
- Architecture questions
- Debugging sessions
- Any time you feel uncertain

---

## BALANCED TOOL WORKFLOW (MANDATORY)


See the detailed workflow below under **BALANCED TOOL WORKFLOW (MANDATORY)** for full guidance and examples.


---

## 🚦 BALANCED TOOL WORKFLOW (MANDATORY)

**Follow this workflow for EVERY task to achieve optimal tool balance:**

### Phase 1: Context First (15-20% of tool calls)

**BEFORE any file/terminal operation, check what you already know:**

```bash
# BEST: One-call aggregated context (especially for complex tasks!)
prepare_context query="[describe what you're trying to do]"

# OR individual queries:
# Search memory for relevant context
memory operation=search query="[topic/file/concept]"

# Ask Mimo for strategic guidance
ask_mimo query="What do I know about [topic]?"

# Query knowledge graph for relationships
knowledge operation=query query="[architecture/dependencies]"
```

### Phase 2: Use Intelligence Tools (15-20% of tool calls)

**Use smart tools instead of brute force:**

```bash
# For code navigation (NOT file search!)
code operation=definition name="functionName"
code operation=references name="className"
code operation=symbols path="src/module.ex"

# For errors (NOT terminal!)
code operation=diagnose path="/project/lib"

# For package docs (NOT web search!)
code operation=library_get name="phoenix" ecosystem=hex
code operation=library_discover path="/project"

# For decisions
cognitive operation=assess topic="[decision to make]"
```

### Phase 3: Action (45-55% of tool calls)

**Now you can use file/terminal:**

```bash
file operation=read path="..."
file operation=edit path="..." old_str="..." new_str="..."
terminal command="mix test" cwd="/project"
```

### Phase 4: Learning (10-15% of tool calls)

**ALWAYS store discoveries:**

```bash
memory operation=store content="[insight]" category=fact importance=0.7
knowledge operation=teach text="[relationship discovered]"
```

### 🎯 Target Tool Distribution

| Phase | Target % | Tools |
|-------|----------|-------|
| Context | 15-20% | memory, ask_mimo, knowledge, meta |
| Intelligence | 15-20% | code, cognitive |
| Action | 45-55% | file, terminal, web |
| Learning | 10-15% | memory store, knowledge teach |

### ⚠️ Mandatory Checkpoints

**CHECKPOINT 1: Before reading ANY file**
```
❌ WRONG: file operation=read path="src/auth.ts"
✅ RIGHT:  memory operation=search query="auth module patterns"
          THEN file operation=read (if still needed)
```

**CHECKPOINT 2: Before searching for code**
```
❌ WRONG: file operation=search pattern="functionName"
✅ RIGHT: code operation=definition name="functionName"
```

**CHECKPOINT 3: Before checking errors**
```
❌ WRONG: terminal command="mix compile"
✅ RIGHT: code operation=diagnose path="/project"
```

**CHECKPOINT 4: Before package documentation**
```
❌ WRONG: web operation=search query="phoenix docs"
✅ RIGHT: code operation=library_get name="phoenix" ecosystem=hex
```

**CHECKPOINT 5: After discoveries**
```
❌ WRONG: Move to next task
✅ RIGHT: memory operation=store content="[what learned]"
```

---

## 🚀 MANDATORY SESSION START

**Every session MUST begin with:**

```bash
# Step 1: Get accumulated context
ask_mimo query="What context do you have about this project and user preferences?"

# Step 2: For new/unknown projects, run onboarding
onboard path="." force=false
```

---

## ❌ ANTI-PATTERNS (Don't Do This)

| ❌ Bad Pattern | ✅ Better Approach |
|---------------|-------------------|
| Jump to editing immediately | `reason` or `think` first → avoid wrong conclusions |
| Skip problem analysis | `reason operation=guided` → understand before acting |
| `file operation=read` immediately | `memory operation=search` first → may already know |
| `file operation=search pattern="func"` for code | `code operation=definition` → semantic, faster |
| `terminal command="mix compile"` for errors | `code operation=diagnose` → structured output |
| `web operation=search query="phoenix docs"` | `code operation=library_get name="phoenix"` → cached |
| Skip after discoveries | `memory operation=store` → compounds knowledge |
| Reading same file repeatedly | Store key facts in memory after first read |
| Describing changes in prose | `file operation=edit` immediately → you have the tools! |
| Outputting code blocks as suggestions | `file operation=write` or `edit` → apply fixes directly |

---

## ⚠️ CRITICAL: You Have Full Development Capabilities via Mimo

**DO NOT ask the user to enable tools or say you cannot edit files!**

**DO NOT just describe changes you would make—ACTUALLY MAKE THEM using Mimo tools!**

When a fix is needed, use `file operation=edit` to apply it immediately. When code needs to be created, use `file operation=write`. Never output code blocks as suggestions when you have the tools to implement directly.

---

## 🧠 MANDATORY: Think Before You Act

**DO NOT jump to conclusions or immediately start editing files!**

For ANY non-trivial task, you MUST reason first:

```bash
# For complex problems - use the full reasoning engine
reason operation=guided problem="[describe what you're trying to solve]" strategy=auto

# For simpler decisions - use think
think operation=plan steps=["step 1", "step 2", "step 3"]

# For uncertainty - assess your confidence
cognitive operation=assess topic="[the decision you're about to make]"
```

### When to Use Each

| Situation | Tool | Example |
|-----------|------|---------|
| Multi-step implementation | `reason operation=guided` | Architecture changes, refactoring |
| Debugging complex issues | `reason operation=guided strategy=reflexion` | Intermittent bugs, race conditions |
| Planning a task | `think operation=plan` | Breaking down user request |
| Quick decision check | `cognitive operation=assess` | "Should I use pattern A or B?" |
| Exploring alternatives | `reason operation=branch` | When first approach might not work |

### The Rule

> **If you're about to make a change and you haven't used `reason`, `think`, or `cognitive`... STOP and think first.**

---

| Capability | Mimo Tool | Example |
|------------|-----------|---------|
| **Edit Files** | `file operation=edit` | `file operation=edit path="src/app.ts" old_str="old" new_str="new"` |
| **Create Files** | `file operation=write` | `file operation=write path="new_file.ts" content="..."` |
| **Read Files** | `file operation=read` | `file operation=read path="src/app.ts"` |
| **Run Commands** | `terminal command="..."` | `terminal command="npm test" cwd="/app"` |
| **Search Files** | `file operation=search` | `file operation=search path="." pattern="TODO"` |
| **Multi-file Edit** | `file operation=multi_replace` | Atomic changes across multiple files |

---

## 🎯 Tool Selection Decision Trees

### Before Reading a File
```
Want to read a file?
        │
        ├─► FIRST: memory operation=search query="[filename] [topic]"
        │          → Already know what you need? Skip the read!
        │
        └─► THEN: file operation=read path="..."
                  → After reading, store key insights in memory
```

### Finding Something in Code
```
Looking for code?
        │
        ├─► Function/class DEFINITION → code operation=definition
        ├─► All USAGES of a symbol   → code operation=references  
        ├─► List symbols in file     → code operation=symbols
        ├─► Call relationships       → code operation=call_graph
        └─► Text/comments/TODOs      → file operation=search
```

### Checking for Errors
```
Need to check errors?
        │
        ├─► Compiler + lint + types → code operation=diagnose (PREFERRED)
        └─► Specific test run       → terminal command="mix test"
```

### Package Documentation
```
Need package docs?
        │
        ├─► FIRST: code operation=library_get name="pkg" ecosystem=hex (cached!)
        └─► ONLY IF NOT FOUND: web operation=search query="pkg documentation"
```

---

## 📋 Quick Reference

```bash
# === SESSION START (MANDATORY) ===
ask_mimo query="What context do you have about this project?"
onboard path="." force=false  # Indexes code, deps, knowledge graph

# === PHASE 1: CONTEXT ===
prepare_context query="[task description]"  # BEST - one call aggregates all!
ask_mimo query="What do I know about [topic]?"
memory operation=search query="[relevant terms]"
knowledge operation=query query="[relationships]"

# === PHASE 2: INTELLIGENCE ===
code operation=definition name="functionName"
code operation=references name="className"
code operation=symbols path="src/module.ex"
code operation=diagnose path="/project/lib"
code operation=library_get name="phoenix" ecosystem=hex
cognitive operation=assess topic="[decision]"

# === COMPOSITE TOOLS (via meta tool) ===
meta operation=analyze_file path="src/module.ex"  # File + symbols + diagnostics + knowledge
meta operation=debug_error message="undefined function foo/2"  # Memory + symbols + diagnostics
meta operation=suggest_next_tool task="implement auth"  # Workflow guidance
meta operation=prepare_context query="complex task"  # Aggregates all context

# === EMERGENCE (via cognitive tool - SPEC-044 Pattern Detection) ===
cognitive operation=emergence_dashboard              # Full metrics and status
cognitive operation=emergence_detect                 # Run pattern detection
cognitive operation=emergence_cycle                  # Full emergence cycle
cognitive operation=emergence_alerts                 # Patterns needing attention
cognitive operation=emergence_suggest topic="..."   # Pattern suggestions for task
cognitive operation=emergence_promote pattern_id="..." # Promote to capability

# === REFLECTOR (via cognitive tool - SPEC-043 Self-Reflection) ===
cognitive operation=reflector_reflect content="..." task="..."  # Deep reflection
cognitive operation=reflector_evaluate content="..."            # Quick evaluation
cognitive operation=reflector_confidence content="..."          # Calibrated confidence
cognitive operation=reflector_errors content="..."              # Error analysis

# === REASONING (SPEC-035 Unified Reasoning Engine) ===
reason operation=guided problem="..." strategy=auto  # Start session
reason operation=step session_id="..." thought="..." # Add step
reason operation=branch session_id="..." thought="..." # ToT branch
reason operation=backtrack session_id="..."          # Go back
reason operation=verify thoughts=["...", "..."]      # Check logic
reason operation=conclude session_id="..."           # Finish
reason operation=reflect session_id="..." success=true result="..."

# === PHASE 3: ACTION ===
file operation=read path="..."
file operation=edit path="..." old_str="..." new_str="..."
file operation=write path="..." content="..."
file operation=glob pattern="**/*.ex" base_path="/project"
file operation=multi_replace replacements=[{...}]
terminal command="mix test" cwd="/project"

# === PHASE 4: LEARNING ===
memory operation=store content="[discovery]" category=fact importance=0.8
knowledge operation=teach text="A depends on B"

# === PROCEDURES ===
run_procedure name="deploy" context={...}
run_procedure name="backup" async=true
run_procedure operation=status execution_id="abc123"
list_procedures
```

---

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
- `Mimo.Tools` - 17 native tools (4 unified + 13 specialized) with 12 deprecated aliases
- `Mimo.Brain` - Cognitive memory: working memory (ETS), episodic (SQLite+vectors), consolidation, decay
- `Mimo.SemanticStore` - Triple-based knowledge graph with inference engine
- `Mimo.ProceduralStore` - FSM execution for deterministic workflows
- `Mimo.Synapse` - Graph RAG with typed nodes/edges and hybrid query

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

### Database Schema
- SQLite via Ecto (`Mimo.Repo`)
- Migrations in `priv/repo/migrations/`
- Schemas: `Mimo.Brain.Engram`, `Mimo.SemanticStore.Triple`, `Mimo.Synapse.GraphNode/GraphEdge`

### Error Handling Pattern
```elixir
# Return tuples, pattern match at call site
{:ok, result} | {:error, reason}
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
mix test                            # Run all tests
mix test test/mimo/synapse/         # Test specific module
mix test --trace                    # Verbose output
```

### Key Environment Variables
| Variable | Purpose |
|----------|---------|
| `MIMO_ROOT` | Sandbox root for file operations |
| `MIMO_API_KEY` | API authentication |
| `OLLAMA_URL` | Embeddings server (default: http://localhost:11434) |
| `OPENROUTER_API_KEY` | Vision/AI features |

## Common Gotchas
- Use `Mimo.DataCase` not `ExUnit.Case` for DB tests
- File ops sandboxed to `MIMO_ROOT` - use absolute paths
- Embeddings require Ollama running (`ollama pull qwen3-embedding:0.6b`)
- MCP stdio mode needs `LOGGER_LEVEL=none` for clean output