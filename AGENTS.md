# Mimo Agent Guide

> **Full documentation**: See [.github/copilot-instructions.md](.github/copilot-instructions.md)

This file provides a **quick reference** for Mimo tool usage.

---

## 🚀 Session Start (MANDATORY)

**Every session MUST begin with:**

```bash
# Step 1: Get accumulated context
ask_mimo query="What context do you have about this project?"

# Step 2: Index project (if new or changed)
onboard path="." force=false
```

---

## ⚠️ Phase 0: Reason First (MANDATORY)

> **NEVER jump to editing files. Assess FIRST.**

```bash
# Step 1: ALWAYS assess confidence
cognitive operation=assess topic="[user request]"

# Step 2: If complex or confidence < 0.8
reason operation=guided problem="[request]" strategy=auto

# Step 3: Create explicit plan
think operation=plan steps=["step1", "step2", "step3"]
```

---

## 🛑 Hard Gates (Check Before ANY Action)

```
□ cognitive operation=assess completed?
□ memory operation=search completed?
□ Have 2+ step plan?
□ Using smart tools (not brute force)?
```

**If ANY box is unchecked → STOP and complete it first.**

---

## 🏃 5-Phase Workflow

```
PHASE 0 → PHASE 1 → PHASE 2 → PHASE 3 → PHASE 4
 REASON   CONTEXT  INTELLIGENCE ACTION   LEARNING
  (10%)   (15-20%)  (15-20%)   (45-55%)  (10-15%)
```

| Phase | Key Tools |
|-------|-----------|
| 0: Reason | `cognitive assess`, `reason guided`, `think plan` |
| 1: Context | `memory search`, `prepare_context`, `ask_mimo` |
| 2: Intelligence | `code definition`, `code diagnose`, `code library_get` |
| 3: Action | `file edit`, `terminal` |
| 4: Learn | `memory store`, `reason reflect` |

---

## 📚 Memory System

### Categories

| Category | Use For | Importance |
|----------|---------|------------|
| `fact` | Verified technical details, patterns | 0.7-0.9 |
| `observation` | User behaviors, preferences | 0.6-0.8 |
| `action` | Completed tasks, implementations | 0.7-0.9 |
| `plan` | Strategies, next steps | 0.5-0.7 |

### Key Operations

```bash
# Search before reading files - you may already know!
memory operation=search query="[topic]" limit=10

# Store discoveries immediately
memory operation=store content="..." category=fact importance=0.8

# Check what's at risk of being forgotten
memory operation=decay_check threshold=0.5
```

---

## 🔗 Knowledge Graph

Use for **relationships** between entities.

```bash
# Query relationships
knowledge operation=query query="what modules depend on X?"

# Teach new relationships
knowledge operation=teach text="auth.ex imports crypto module"

# Traverse from a node
knowledge operation=traverse node_id="module:auth" direction=outgoing
```

---

## 🔍 Code Intelligence

| Need | Operation | Example |
|------|-----------|---------|
| Where is X defined? | `definition` | `code operation=definition name="authenticate"` |
| Where is X used? | `references` | `code operation=references name="UserService"` |
| What's in this file? | `symbols` | `code operation=symbols path="lib/auth.ex"` |
| Check all errors | `diagnose` | `code operation=diagnose path="lib/"` |

### Library Documentation (BEFORE web search!)

```bash
code operation=library_get name="phoenix" ecosystem=hex
code operation=library_discover path="."
```

---

## 🌐 Web Strategy

```
Need external info?
    │
    ├─► Package docs? → code operation=library_get (FIRST!)
    ├─► Already in memory? → memory operation=search
    └─► Not cached? → web operation=search query="..."
```

---

## 🧠 Reasoning

| Situation | Tool | Strategy |
|-----------|------|----------|
| Complex implementation | `reason guided` | auto |
| Debugging | `reason guided` | reflexion |
| Multiple approaches | `reason guided` | tot |
| Quick planning | `think plan` | - |
| Confidence check | `cognitive assess` | - |

```bash
reason operation=guided problem="..." strategy=auto
reason operation=step session_id="..." thought="..."
reason operation=conclude session_id="..."
reason operation=reflect session_id="..." success=true result="..."
```

---

## ❌ Anti-Patterns

| ❌ Violation | ✅ Correct Approach |
|-------------|---------------------|
| Jump to editing immediately | `cognitive assess` + `reason guided` first |
| `file read` before memory | `memory search` first |
| `file search pattern="func"` | `code definition name="func"` |
| `terminal command="mix compile"` for errors | `code diagnose path="..."` |
| `web search query="phoenix docs"` | `code library_get name="phoenix"` |
| Skip storing discoveries | `memory store` after task |
| Describe changes in prose | `file edit` directly — apply fixes! |

---

## 🔧 Development Only

### Project Structure
```
lib/mimo/          - Main modules
lib/mimo/skills/   - Tool implementations  
lib/mimo/tools/    - Tool dispatchers
test/mimo/         - Tests
```

### Commands
```bash
mix deps.get && mix ecto.migrate  # Setup
mix test                          # Tests
./bin/mimo stdio                  # MCP mode
```

### Environment Variables
| Variable | Purpose |
|----------|---------|
| `MIMO_ROOT` | File sandbox root |
| `OLLAMA_URL` | Embeddings server |
| `OPENROUTER_API_KEY` | AI features |

---

**Order: THINK → CONTEXT → INTELLIGENCE → ACTION → LEARN**
