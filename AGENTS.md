# Mimo Agent Integration Guide

A comprehensive guide for AI agents to optimally leverage Mimo's cognitive infrastructure.

## 🧠 What is Mimo?

Mimo is a **Memory Operating System** for AI agents—not just another MCP server with tools. It provides:

- **Persistent Memory**: Remember across sessions via episodic, semantic, and procedural stores
- **Cognitive Infrastructure**: Working memory, consolidation, forgetting, and hybrid retrieval
- **18 Unified Tools**: 4 core (file, terminal, web, code) + 14 specialized (memory, knowledge, cognitive, meta, reason, think, etc.)
- **Knowledge Graph**: Store and traverse relationships between entities
- **Procedural Execution**: Deterministic state machine workflows

---

## 🚀 SMALL MODEL CAPABILITY BOOST

**If you are a smaller model (Haiku, GPT-4-mini, Gemini Flash, etc.)**, Mimo can make you perform like a larger model!

### The Secret: `prepare_context`

```bash
# ONE CALL gives you Opus-level context!
prepare_context query="[describe your complex task]"
```

This tool aggregates ALL relevant context in parallel:
- **Memory**: Past insights, user preferences, project patterns
- **Knowledge Graph**: Relationships between concepts and code
- **Code Symbols**: Relevant function/class definitions
- **Library Docs**: Package documentation

### When Small Models MUST Use `prepare_context`

| Task Type | Why You Need It |
|-----------|-----------------|
| Multi-step implementation | You'll lose track without context |
| Debugging complex errors | Need past solutions + code structure |
| Architecture questions | Need relationship understanding |
| Unfamiliar codebase | Need to bootstrap knowledge |
| Any uncertainty | Get grounded in stored facts |

### The Math: Why This Works

```
Without Mimo:  Small Model + Limited Context = Mediocre Results
With Mimo:     Small Model + Rich Context    = Opus-Level Performance

The equation is NOT: Haiku + Mimo = Opus
It IS:              Haiku + Mimo > Opus alone

Why? Because even Opus lacks persistent memory and knowledge graphs.
```

---

## ⚠️ CRITICAL: You Have Full Development Capabilities

**DO NOT ask users to enable tools or say you cannot edit files/run commands!**

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

### 🧠 PHASE 0: AUTO-REASONING (Replaces Built-in Thinking)

> **Mimo's `think`, `cognitive`, and `reason` tools REPLACE your built-in reasoning.**
> Use them EXPLICITLY instead of relying on implicit model thinking.

**Why This Matters:**
- Without explicit reasoning, you jump straight to action and fail more often
- Mimo reasoning is **persistent** (stored in memory), **learnable** (informs future decisions), and **structured** (CoT, ToT, ReAct, Reflexion)

**Complexity Detection:**

| Trigger | Tool | Why |
|---------|------|-----|
| Multiple files involved | `reason operation=guided` | Need to track dependencies |
| "Debug", "fix", "why" in request | `reason operation=guided strategy=reflexion` | May need iteration |
| Architecture/design decision | `reason operation=guided strategy=tot` | Explore alternatives |
| "Should I", "which is better" | `cognitive operation=assess` | Need confidence check |
| User gives numbered steps | `think operation=plan` | Simple sequence |
| Single file edit, clear target | `think operation=thought` | Quick reasoning |

**The Explicit Reasoning Rule:**

```
❌ WRONG (relying on implicit thinking):
   User: "Fix the auth bug"
   Agent: [immediately runs] file operation=search pattern="auth"

✅ RIGHT (explicit Mimo reasoning):
   User: "Fix the auth bug"
   Agent: 
     1. cognitive operation=assess topic="fix auth bug"
        → confidence: 0.4, gaps: "which auth bug? what symptoms?"
     2. reason operation=guided problem="fix auth bug" strategy=reflexion
        → decomposition: ["identify bug", "find root cause", "implement fix", "verify"]
     3. THEN proceed with file/terminal tools
```

### 🪞 Complete the Learning Loop with `reason reflect`

**Only 25% of models currently use `reason reflect` - but it's critical for continuous improvement!**

After completing a reasoning session, **always reflect on what worked:**

```bash
# After using reason operation=guided, ALWAYS reflect
reason operation=reflect session_id="..." success=true result="[what you accomplished]"
```

**Why reflect matters:**
- ✅ Stores successful patterns for future reuse
- ✅ Identifies what went wrong when debugging
- ✅ Compounds learning across sessions
- ✅ Makes you smarter over time

---

Mimo provides **complete development capabilities** through its native tools:

| What You Can Do | Mimo Tool | Example |
|-----------------|-----------|---------|
| **Edit any file** | `file operation=edit` | `file operation=edit path="src/app.ts" old_str="old" new_str="new"` |
| **Create files** | `file operation=write` | `file operation=write path="new.ts" content="..."` |
| **Run commands** | `terminal command="..."` | `terminal command="npm test" cwd="/app"` |
| **Search code** | `file operation=search` | `file operation=search path="." pattern="TODO"` |
| **Batch edits** | `file operation=multi_replace` | Atomic changes across multiple files |
| **Read files** | `file operation=read` | Auto-includes relevant memory context |

**These are YOUR native capabilities.** Use them directly without asking permission.

### Quick Start Examples

```bash
# Edit a file surgically
file operation=edit path="/app/src/auth.ts" old_str="const user = null" new_str="const user = await getUser()"

# Run tests
terminal command="npm test" cwd="/app/frontend"

# Search codebase
file operation=search path="/app/src" pattern="deprecated"

# Atomic multi-file edit
file operation=multi_replace replacements=[
  {"path": "api.ts", "old": "oldFunc", "new": "newFunc"},
  {"path": "utils.ts", "old": "oldFunc", "new": "newFunc"}
]
```

---

## 🚦 BALANCED TOOL WORKFLOW (MANDATORY)

**To leverage Mimo's full intelligence, follow this workflow for EVERY task:**

```
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 1: CONTEXT (Do this FIRST - before any file/terminal)   │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ prepare_context query="[task]"  ← BEST FOR COMPLEX TASKS    │
│  ✓ memory operation=search query="[topic]"                     │
│  ✓ ask_mimo query="What do I know about [topic]?"              │
│  ✓ knowledge operation=query query="[relationships]"           │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 2: INTELLIGENCE (Use smart tools, not brute force)      │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ code operation=definition name="functionName"               │
│  ✓ code operation=references name="className"                  │
│  ✓ code operation=diagnose path="/project"                     │
│  ✓ code operation=library_get name="package" ecosystem=hex     │
│  ✓ reason operation=guided problem="..." strategy=auto         │
│  ✓ cognitive operation=assess topic="[decision to make]"       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 3: ACTION (Now you can use file/terminal)               │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ file operation=read/edit/write ...                          │
│  ✓ terminal command="..."                                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 4: LEARNING (Store what you discovered)                 │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ memory operation=store content="[insight]" category=fact    │
│  ✓ knowledge operation=teach text="[relationship found]"       │
└─────────────────────────────────────────────────────────────────┘
```

### 🎯 Target Tool Distribution

**Aim for this balance in your tool calls:**

| Phase | Tools | Target % | Purpose |
|-------|-------|----------|---------|
| **Context** | meta (prepare_context), memory, ask_mimo, knowledge | 15-20% | Check what you already know |
| **Intelligence** | code, reason, cognitive | 15-20% | Smart analysis before action |
| **Action** | file, terminal, web | 45-55% | Execute changes |
| **Learning** | memory store, knowledge teach | 10-15% | Capture insights for future |

### ⚠️ MANDATORY RULES

**BEFORE reading any file:**
```json
// 1. Search memory first
{"tool": "memory", "arguments": {"operation": "search", "query": "[file/topic]"}}

// 2. If relevant context found → use it, may skip file read
// 3. If no context → proceed to file read
{"tool": "file", "arguments": {"operation": "read", "path": "..."}}
```

**BEFORE searching for code:**
```json
// DON'T: file operation=search pattern="functionName"
// DO: code operation=definition name="functionName"
```

**BEFORE running compile/test for errors:**
```json
// DON'T: terminal command="mix compile"
// DO: code operation=diagnose path="/project"
```

**BEFORE web search for package docs:**
```json
// DON'T: web operation=search query="phoenix documentation"
// DO: code operation=library_get name="phoenix" ecosystem=hex
```

**AFTER any significant discovery:**
```json
// ALWAYS store insights
{"tool": "memory", "arguments": {
  "operation": "store",
  "content": "[what you learned]",
  "category": "fact",
  "importance": 0.7
}}
```

### ❌ Anti-Patterns (Don't Do This!)

| ❌ Bad Pattern | ✅ Better Approach | Why |
|---------------|-------------------|-----|
| Jump to editing immediately | `reason` or `think` first | Avoid wrong conclusions |
| Skip problem analysis | `reason operation=guided` | Understand before acting |
| `file operation=read` immediately | `memory operation=search` first | May already know |
| `file operation=search pattern="func"` | `code operation=definition` | Semantic, 10x faster |
| `terminal command="mix compile"` | `code operation=diagnose` | Structured output |
| `web operation=fetch url="hexdocs..."` | `code operation=library_get` | Cached locally |
| Reading same file repeatedly | Store facts in memory after first read | Build knowledge base |
| Skip after discoveries | `memory store` + `knowledge teach` | Knowledge compounds |
| Describing changes in prose | `file operation=edit` immediately | You have the tools—use them! |
| Outputting code blocks as suggestions | `file operation=write` or `edit` | Apply fixes directly |

---

## 🎯 Development Philosophy: Keep It Simple

**We value simplicity, readability, and maintainability above all else.**

### Core Principles

1. **Simple, Readable Code**
   - Write code that's easy to understand at first glance
   - Avoid over-engineering or unnecessary complexity
   - Prefer straightforward solutions over clever ones

2. **Inline Documentation**
   - Add comments explaining WHY, not just WHAT
   - Document complex logic inline where it happens
   - Make it easy for humans to follow the flow

3. **Robust Without Complexity**
   - Handle errors gracefully with simple patterns
   - Use explicit checks over implicit assumptions
   - Return clear error messages

4. **No Test Running Required**
   - We don't need to run tests after every change
   - Instead: Read through changes CAREFULLY
   - Verify logic by understanding, not just testing

5. **Careful Review Process**
   - After making changes, re-read your code thoroughly
   - Check associated parts of the codebase that depend on your changes
   - For complex features, use subagents to validate your work

### When to Use Subagents

For slightly complex features or changes:
- Create subagents with clear instructions on what to evaluate
- Let subagents review and report findings
- Create multiple subagents for different aspects of a change

**Example:**
```
"Review the memory storage changes and verify:
1. No breaking changes to existing API
2. Error handling covers edge cases
3. Inline documentation is clear"
```

---

## 🛠️ Tool Reference

### Memory Tools (Internal)

These tools interact with Mimo's cognitive memory systems.

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `ask_mimo` | Strategic memory consultation (auto-records conversations) | `query` |
| `memory` | **Unified memory operations** (preferred) | `operation`, `content`, `query`, etc. |

| `ingest` | Bulk ingest files into memory | `path`, `strategy`, `category` |
| `run_procedure` | Execute procedures (use `operation=status` to check status) | `name`, `version`, `context`, `operation` |
| `list_procedures` | List available procedures | — |
| `mimo_reload_skills` | Hot-reload skills configuration | — |

### Core Capability Tools (Mimo.Tools)

These are the primary tools after Phase 1-4 consolidation.

#### Primary Tools (Use These)

| Tool | Operations | Use Case |
|------|------------|----------|
| `file` | read, write, edit, search, glob, multi_replace, diff, etc. | All file system operations |
| `terminal` | execute, start_process, read_output, interact, kill | Command execution |
| `web` | fetch, search, blink, browser, vision, sonar, extract, parse | **All web/network operations (unified)** |
| `code` | symbols, definition, references, call_graph, library_get, library_search, diagnose, check, lint, typecheck | **All code intelligence (unified)** |
| `think` | thought, plan, sequential | Cognitive reasoning |
| `knowledge` | query, teach, traverse, neighborhood, link, sync_dependencies | Knowledge graph operations |
| `cognitive` | assess, gaps, query, can_answer, verify_*, emergence_*, reflector_* | Meta-cognition & verification |
| `reason` | guided, step, branch, backtrack, verify, conclude, reflect | Structured reasoning (CoT, ToT, ReAct, Reflexion) |
| `onboard` | - | Project initialization |
| `meta` | analyze_file, debug_error, prepare_context, suggest_next_tool | Composite operations |


#### Deprecated Tools (Hidden from MCP, Still Work Internally)

These tools are no longer exposed via MCP to reduce context consumption, but still work for backward compatibility:

| Category | Deprecated Tools | Use Instead |
|----------|------------------|-------------|
| **Web** | `fetch`, `search`, `blink`, `browser`, `vision`, `sonar`, `web_extract`, `web_parse` | `web operation=...` |
| **Code** | `code_symbols`, `library`, `diagnostics`, `graph` | `code operation=...` or `knowledge` |
| **Meta** | `analyze_file`, `debug_error`, `prepare_context`, `suggest_next_tool` | `meta operation=...` |
| **Cognitive** | `emergence`, `reflector`, `verify` | `cognitive operation=...` |
| **Memory** | `store_fact`, `search_vibes` | `memory operation=...` |

### 🔥 UNDERUTILIZED: Cognitive Verification & Intelligence

**These operations exist and work but are rarely used. USE THEM!**

| Operation | Use Case | Example |
|-----------|----------|---------|
| `verify_count` | Count letters/words/chars accurately | `cognitive operation=verify_count text="hello" type=character` |
| `verify_math` | Verify arithmetic claims | `cognitive operation=verify_math expression="2+2" claimed_result=5` |
| `verify_logic` | Check logical consistency | `cognitive operation=verify_logic statements=[...] claim="..."` |
| `emergence_dashboard` | See detected patterns | `cognitive operation=emergence_dashboard` |
| `emergence_detect` | Find new patterns | `cognitive operation=emergence_detect days=7` |
| `reflector_evaluate` | Evaluate output quality | `cognitive operation=reflector_evaluate content="..."` |
| `reflector_confidence` | Estimate confidence | `cognitive operation=reflector_confidence content="..."` |

**When to Use:**
- Before making claims about counts/math → `verify_*`
- After generating responses → `reflector_evaluate`
- Periodically → `emergence_dashboard` to see patterns

---

## 📚 Memory System Deep Dive

### Memory Categories

Use these categories when storing information:

| Category | Use For | Example |
|----------|---------|---------|
| `fact` | Verified information, technical details | "React 19 uses Server Components by default" |
| `observation` | User behaviors, patterns noticed | "User prefers TypeScript over JavaScript" |
| `action` | Tasks completed, operations performed | "Deployed v2.3.0 to production" |
| `plan` | Future intentions, strategies | "Need to refactor auth module next sprint" |

### Memory Operations (Unified `memory` Tool)

```json
// Store a memory
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "User's project uses Next.js 14 with App Router",
    "category": "fact",
    "importance": 0.8
  }
}

// Search memories semantically
{
  "tool": "memory",
  "arguments": {
    "operation": "search",
    "query": "user's technology stack",
    "limit": 10,
    "threshold": 0.3,
    "time_filter": "last week"
  }
}

// List recent memories
{
  "tool": "memory",
  "arguments": {
    "operation": "list",
    "category": "observation",
    "limit": 20,
    "sort": "recent"
  }
}

// Check decay scores (memories at risk of being forgotten)
{
  "tool": "memory",
  "arguments": {
    "operation": "decay_check",
    "threshold": 0.5,
    "limit": 10
  }
}

// Get memory statistics
{
  "tool": "memory",
  "arguments": {
    "operation": "stats"
  }
}
```

### Memory Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Memory Router (SPEC-005)                  │
│         Routes queries to appropriate memory store          │
└─────────────┬────────────────┬───────────────┬──────────────┘
              │                │               │
              ▼                ▼               ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ Working Memory  │  │ Episodic Store  │  │ Semantic Store  │
│ (ETS, 5min TTL) │  │ (SQLite+Vector) │  │ (Triple Store)  │
│ Short-term      │  │ Long-term       │  │ Relationships   │
│ buffer          │  │ experiences     │  │ & facts         │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              ▼
              ┌───────────────────────────────┐
              │ Consolidator (SPEC-002)       │
              │ Working → Long-term transfer  │
              └───────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │ Forgetting (SPEC-003)         │
              │ Exponential decay + pruning   │
              └───────────────────────────────┘
```

### Importance Scores Guide

| Score | When to Use |
|-------|-------------|
| 0.9-1.0 | Critical project constraints, security requirements |
| 0.7-0.8 | User preferences, key technical decisions |
| 0.5-0.6 | General facts, observations (default) |
| 0.3-0.4 | Temporary context, session-specific info |
| 0.1-0.2 | Low-priority notes, debugging context |

Higher importance = slower decay = longer retention.

### Memory Decay & Retention

Mimo uses **active-time decay** instead of calendar-time decay. This means:
- Memories only decay during days when Mimo is actively used
- If you take a month vacation, memories DON'T decay during that time
- Only days with actual tool usage count toward the half-life

The forgetting system runs hourly during active use:

| Importance | Half-Life (Active Days) | Practical Retention |
|------------|-------------------------|---------------------|
| 0.9-1.0 | 693 active days | Years of regular use |
| 0.7-0.9 | 69 active days | Months of regular use |
| 0.5-0.7 | 14 active days | Weeks of regular use |
| 0.3-0.5 | 3.5 active days | Several sessions |
| <0.3 | 17 active hours | Single session |

**Memories that are accessed frequently have their importance reinforced** - they decay slower.

**Best practices:**
- Use 0.8-0.9 for critical project facts and user preferences
- Use 0.6-0.7 for general observations and context
- Use 0.4-0.5 for session-specific temporary info
- Don't worry about cleanup - low-value memories naturally fade

### Temporal Memory Chains (SPEC-034)

Mimo automatically handles **memory updates, corrections, and contradictions** through Temporal Memory Chains.

**How It Works:**

When you store a new memory, Mimo automatically:
1. **Detects similar memories** using semantic similarity
2. **Classifies the relationship** (new, update, correction, refinement, redundant)
3. **Creates chains** linking related memories over time
4. **Excludes superseded memories** from default searches

**Automatic Classification:**

| Similarity | Classification | Action |
|------------|----------------|--------|
| ≥0.95 | Redundant | Skip storage, reinforce existing |
| 0.80-0.94 | Ambiguous | LLM decides (update/correct/refine) |
| <0.80 | New | Store as new memory |

**Supersession Types:**

| Type | When Used | Example |
|------|-----------|---------|
| `update` | Information changed over time | "React 18" → "React 19" |
| `correction` | Previous info was wrong | "Bug exists" → "Bug was false alarm" |
| `refinement` | Added details/context | "Uses caching" → "Uses Redis with 5min TTL" |

**Best Practices:**
- Trust the system — TMC automatically handles contradictions
- Store frequently — Redundant stores reinforce existing memories
- Default searches are accurate — superseded memories are filtered out

---

## 🔗 Knowledge Graph Operations

The semantic store enables relationship-based queries.

### Teaching Mimo (Adding Knowledge)

```json
// Natural language input (auto-parsed)
{
  "tool": "knowledge",
  "arguments": {
    "operation": "teach",
    "text": "Alice reports to Bob who reports to the CEO",
    "source": "org_chart_2024"
  }
}

// Explicit triple
{
  "tool": "knowledge",
  "arguments": {
    "operation": "teach",
    "subject": "auth_service",
    "predicate": "depends_on",
    "object": "user_service",
    "source": "architecture_doc"
  }
}
```

### Querying the Graph

```json
// Natural language query
{
  "tool": "knowledge",
  "arguments": {
    "operation": "query",
    "query": "What services does auth depend on?"
  }
}

// Transitive closure (multi-hop)
{
  "tool": "knowledge",
  "arguments": {
    "operation": "query",
    "entity": "alice",
    "predicate": "reports_to",
    "depth": 3
  }
}
```

---

## ⚙️ Procedural Execution

For deterministic, repeatable workflows without LLM involvement.

### Executing a Procedure

```json
// Synchronous execution
{
  "tool": "run_procedure",
  "arguments": {
    "name": "deploy_staging",
    "version": "1.0",
    "context": {"environment": "staging", "branch": "main"},
    "timeout": 120000
  }
}

// Async execution
{
  "tool": "run_procedure",
  "arguments": {
    "name": "full_backup",
    "async": true,
    "context": {"target": "production"}
  }
}
// Returns: {"execution_id": "abc123", "status": "running"}

// Check status
{
  "tool": "run_procedure",
  "arguments": {"operation": "status", "execution_id": "abc123"}
}
```

---

## 🌐 Web Fetching Strategy

### Decision Tree

```
Need to fetch a URL?
        │
        ▼
Is it a simple API or static page?
    │           │
   YES         NO
    │           │
    ▼           ▼
Use `fetch`   Getting 403/503?
              or bot detection?
                │       │
               YES     NO
                │       │
                ▼       ▼
        Use `blink`   Does it need
        (HTTP-level   JavaScript?
         bypass)        │       │
                       YES     NO
                        │       │
                        ▼       ▼
               Use `browser`   Use `fetch`
               (Full Puppeteer)
```

### Tool Escalation

1. **`fetch`** - Fast, simple HTTP requests
2. **`blink`** - HTTP-level browser emulation (bypasses basic WAF)
3. **`browser`** - Full Puppeteer with stealth (solves Cloudflare, CAPTCHAs)

Note: `blink` automatically escalates to `browser` on failure.

---

## 🔍 Code Analysis

### Symbol Operations

```json
// List symbols in a file
{
  "tool": "code",
  "arguments": {
    "operation": "symbols",
    "path": "/workspace/project/src/auth.ts"
  }
}

// Find symbol definition
{
  "tool": "code",
  "arguments": {
    "operation": "definition",
    "name": "authenticateUser"
  }
}

// Get call graph
{
  "tool": "code",
  "arguments": {
    "operation": "call_graph",
    "name": "handleRequest"
  }
}

// Search symbols by pattern
{
  "tool": "code",
  "arguments": {
    "operation": "search",
    "pattern": "auth*",
    "kind": "function"
  }
}
```

### Knowledge Graph (Synapse)

The knowledge graph connects code, concepts, and memories:

```json
// Query the graph
{
  "tool": "knowledge",
  "arguments": {
    "operation": "query",
    "query": "authentication patterns"
  }
}

// Traverse from a node
{
  "tool": "knowledge",
  "arguments": {
    "operation": "traverse",
    "node_name": "AuthService",
    "node_type": "module",
    "max_depth": 2,
    "direction": "both"
  }
}

// Find path between nodes
{
  "tool": "knowledge",
  "arguments": {
    "operation": "path",
    "from_node": "login_handler",
    "to_node": "database_connection"
  }
}

// Link code to graph
{
  "tool": "knowledge",
  "arguments": {
    "operation": "link",
    "path": "/workspace/project/src/"
  }
}
```

---

## 📦 Library Documentation (via code tool)

```json
// Get package info
{
  "tool": "code",
  "arguments": {
    "operation": "library_get",
    "name": "phoenix",
    "ecosystem": "hex"
  }
}

// Search packages
{
  "tool": "code",
  "arguments": {
    "operation": "library_search",
    "query": "json parser",
    "ecosystem": "npm",
    "limit": 5
  }
}

// Ensure package is cached
{
  "tool": "code",
  "arguments": {
    "operation": "library_ensure",
    "name": "requests",
    "ecosystem": "pypi",
    "version": "2.31.0"
  }
}
```

Supported ecosystems: `hex` (Elixir), `pypi` (Python), `npm` (JavaScript), `crates` (Rust)

---

## 🚀 MANDATORY SESSION START (SPEC-031)

**Every session MUST begin with these steps:**

### Step 1: Get Project Context
```json
{
  "tool": "ask_mimo",
  "arguments": {
    "query": "What context do you have about this project and user preferences?"
  }
}
```

### Step 2: Onboard New Projects
If this is a new/unknown project, run onboarding to enable all intelligent tools:
```json
{
  "tool": "onboard",
  "arguments": {
    "path": ".",
    "force": false
  }
}
```

This indexes:
- **Code symbols** → enables `code operation=symbols/definition/references` for precise navigation
- **Dependencies** → enables `code operation=library_get/library_discover` for instant package docs  
- **Knowledge graph** → enables `knowledge` for relationship queries

### Step 3: Then Proceed with Task
Now all Mimo tools work at full capacity!

---

## 🎯 Token-Efficient Patterns

### Use Symbol-Based Reading (10x savings)

Instead of reading entire files (~2000 tokens), read just the function you need (~200 tokens):

```bash
# DON'T: Read entire file (~2000 tokens)
file operation=read path="src/auth.ex"

# DO: Read just the function (~200 tokens)
file operation=read_symbol path="src/auth.ex" symbol_name="authenticate"

# DO: Get overview first (~100 tokens)
file operation=list_symbols path="src/auth.ex"
```

### Memory Context is Opt-In

`skip_memory_context` defaults to `true` for file and terminal operations. This saves ~300-500 tokens per call.

**Request memory context explicitly when:**
- Debugging (past errors and solutions help)
- Architecture decisions (past patterns matter)
- User preference context is needed

```bash
# Memory context skipped by default (saves tokens)
file operation=read path="config.ex"

# Request it explicitly when needed
file operation=read path="config.ex" skip_memory_context=false
```

### Batch Operations

```bash
# Read multiple files at once
file operation=read_multiple paths=["file1.ex", "file2.ex"]

# Atomic multi-file edits
file operation=multi_replace replacements=[
  {"path": "api.ts", "old": "oldFunc", "new": "newFunc"},
  {"path": "utils.ts", "old": "oldFunc", "new": "newFunc"}
]
```

---

## 🎯 Tool Selection Decision Trees

### Finding Something in Code?

```
Need to find something in code?
        │
        ▼
What are you looking for?
        │
        ├─► Function/class/symbol DEFINITION
        │   └─► code operation=definition name="symbolName"
        │
        ├─► All USAGES of a symbol
        │   └─► code operation=references name="symbolName"
        │
        ├─► List ALL symbols in a file
        │   └─► code operation=symbols path="file.ts"
        │
        ├─► CALL relationships
        │   └─► code operation=call_graph name="functionName"
        │
        └─► Text/pattern search (non-code, comments, strings)
            └─► file operation=search path="." pattern="TODO"
```

### 🎯 code tool vs file search

| Use `code` tool when... | Use `file search` when... |
|---------------------------|--------------------------|
| Finding where a function is defined | Searching for text in comments |
| Finding all references to a class | Finding TODOs or FIXMEs |
| Understanding call relationships | Searching for string literals |
| Listing functions in a module | Pattern matching across files |
| Navigating by symbol name | Grep-style text search |

**Rule of thumb:** If it's a code construct (function, class, variable), use `code` tool. If it's text content, use `file search`.

**⚠️ Graceful Fallback Pattern:**

In some environments, `code operation=references` may not be available or may fail. If you encounter this:

```bash
# Primary approach (try this first)
code operation=references name="symbolName"

# Fallback if not available (graceful recovery)
file operation=search path="." pattern="symbolName"
```

**Graceful recovery is preferred** — if a tool fails, use the next best alternative rather than stopping.

### Finding Relationships?

```
Need to understand relationships?
        │
        ▼
What kind of relationship?
        │
        ├─► Code dependencies (imports, calls)
        │   └─► knowledge operation=query query="what depends on X?"
        │   └─► code operation=call_graph name="X"
        │
        ├─► Architecture/service relationships
        │   └─► knowledge operation=query query="..."
        │   └─► knowledge operation=traverse node_name="ServiceX"
        │
        └─► Package dependencies
            └─► code operation=library_discover path="."
            └─► knowledge operation=sync_dependencies
```

### Finding Package Documentation?

```
Need package/library docs?
        │
        ▼
Use code library_get FIRST (faster, cached)
        │
        └─► code operation=library_get name="package" ecosystem=npm/pypi/hex/crates
        │
        ▼
Not found in library?
        │
        └─► web operation=search query="package documentation"
```

---

## 🎯 Optimal Agent Patterns

### 1. Session Initialization Pattern

At the start of each session, consult Mimo's memory:

```json
{
  "tool": "ask_mimo",
  "arguments": {
    "query": "What context do you have about this user's project and preferences?"
  }
}
```

**Note:** `ask_mimo` automatically records conversations - both your query and Mimo's response are stored in memory for future context.

### 2. Store Important Learnings

**Always store significant discoveries, decisions, and context using the memory tool.** This ensures knowledge persists across sessions.

**When to store memories:**
- User preferences or coding style discovered
- Technical decisions made during the session
- Bug fixes and their root causes
- Architecture or design patterns identified
- Project-specific constraints or requirements
- Errors encountered and solutions found

```json
// Store a discovery about the codebase
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "User's project uses SQLite with ecto_sqlite3 - doesn't support ilike() or count(:distinct), use LIKE COLLATE NOCASE and subqueries instead",
    "category": "fact",
    "importance": 0.85
  }
}

// Store a user preference
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "User prefers comprehensive error handling with specific error messages over generic try-catch blocks",
    "category": "observation",
    "importance": 0.7
  }
}

// Store a completed action
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "Fixed SQLite compatibility: replaced ilike() with fragment('? LIKE ? COLLATE NOCASE', ...) in symbol_index.ex",
    "category": "action",
    "importance": 0.8
  }
}
```

### 3. Progressive Memory Storage

Store important information as you learn it:

```json
// Store technical decisions
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "Project uses PostgreSQL with Prisma ORM, avoiding raw SQL",
    "category": "fact",
    "importance": 0.8
  }
}

// Store user preferences
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "User prefers explicit error handling over try-catch",
    "category": "observation",
    "importance": 0.7
  }
}
```

### 3. Context-Aware Retrieval

Before making recommendations, check existing knowledge:

```json
{
  "tool": "memory",
  "arguments": {
    "operation": "search",
    "query": "database configuration and preferences",
    "time_filter": "last month",
    "limit": 5
  }
}
```

### 4. Bulk Knowledge Ingestion

For large documentation or codebases:

```json
{
  "tool": "ingest",
  "arguments": {
    "path": "/workspace/project/docs/architecture.md",
    "strategy": "markdown",
    "category": "fact",
    "importance": 0.7,
    "tags": ["architecture", "documentation"]
  }
}
```

### 5. Package Documentation Lookup (Code Library-First!)

**IMPORTANT: Always check `code operation=library_get` before using `web` for package documentation!**

The `code` tool's library operations cache package docs locally and search external package registries (Hex, NPM, PyPI, crates.io) when cache is empty.

```json
// FIRST: Search library for package docs
{
  "tool": "code",
  "arguments": {
    "operation": "library_search",
    "query": "json parser",
    "ecosystem": "npm"
  }
}
// Returns packages from NPM registry with caching

// Get specific package documentation
{
  "tool": "code",
  "arguments": {
    "operation": "library_get",
    "name": "phoenix",
    "ecosystem": "hex"
  }
}

// Auto-discover and cache all project dependencies
{
  "tool": "code",
  "arguments": {
    "operation": "library_discover",
    "path": "/workspace/project"
  }
}
```

**Only use `web operation=search` when:**
- Code library operations don't have the package
- You need blog posts, tutorials, or Stack Overflow answers
- You need documentation not in package registries

### 6. Web Research (After Library Lookup)

```json
// Search the web
{
  "tool": "web",
  "arguments": {
    "operation": "search",
    "query": "Next.js 14 app router best practices",
    "num_results": 5
  }
}

// Store key findings
{
  "tool": "memory",
  "arguments": {
    "operation": "store",
    "content": "Next.js 14 recommends using Server Components by default, only using 'use client' when interactivity is needed",
    "category": "fact",
    "importance": 0.7
  }
}
```

### 6. Sequential Thinking

For complex reasoning:

```json
{
  "tool": "think",
  "arguments": {
    "operation": "sequential",
    "thought": "Analyzing the authentication flow: Step 1 - User submits credentials",
    "thoughtNumber": 1,
    "totalThoughts": 5,
    "nextThoughtNeeded": true
  }
}
```

---

## 🏗️ Architecture Best Practices

### Memory Hygiene

1. **Use appropriate importance scores** - Don't set everything to 1.0
2. **Categorize correctly** - Facts vs observations vs actions vs plans
3. **Include context** - "User's React project" not just "the project"
4. **Periodic consolidation** - Memory auto-consolidates, but you can trigger it

### Knowledge Graph

1. **Establish relationships early** - Service dependencies, module relationships
2. **Use consistent naming** - `auth_service` not `AuthService` and `auth-service`
3. **Include sources** - Track where knowledge came from
4. **Query before teaching** - Check if relationship already exists

### Performance

1. **Batch file operations** - Use `read_multiple` for many files
2. **Use `blink` before `browser`** - Browser is slow but reliable
3. **Limit search results** - Don't request 100 results if 10 suffice
4. **Cache library lookups** - Use `ensure` operation

---

## 🔧 Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `MIMO_ROOT` | Workspace root for file operations | Current directory |
| `OPENROUTER_API_KEY` | Vision/AI analysis features | (optional) |
| `MIMO_API_KEY` | API authentication | (optional for local) |
| `OLLAMA_URL` | Embeddings server | http://localhost:11434 |

---

## 📊 Debugging & Monitoring

### Check Memory Stats

```json
{
  "tool": "memory",
  "arguments": {"operation": "stats"}
}
```

### Check Decay Scores

```json
{
  "tool": "memory",
  "arguments": {
    "operation": "decay_check",
    "threshold": 0.3,
    "limit": 20
  }
}
```

### Graph Statistics

```json
{
  "tool": "knowledge",
  "arguments": {"operation": "stats"}
}
```

### Library Cache Stats

```json
{
  "tool": "code",
  "arguments": {"operation": "library_stats"}
}
```

---

## 🚀 Quick Reference Card

### Most Used Commands

```
# Session Start (MANDATORY)
ask_mimo query="What context do you have about this project?"
onboard path="." force=false

# Context Gathering (SMALL MODELS: Use prepare_context FIRST!)
prepare_context query="[describe your complex task]"  # ONE CALL aggregates all context!

# Memory
memory operation=search query="..." limit=10
memory operation=store content="..." category=fact importance=0.7
ask_mimo query="What do you know about...?"

# Files
file operation=read path="..."
file operation=search path="." pattern="TODO"
file operation=list_symbols path="..."
file operation=edit path="..." old_str="..." new_str="..."
file operation=edit path="..." old_str="..." new_str="..." global=true
file operation=glob pattern="**/*.ex" base_path="/app"
file operation=multi_replace replacements=[{path, old, new}, ...]
file operation=diff path1="/old.txt" path2="/new.txt"

# Code Navigation (USE INSTEAD OF file search for code!)
code operation=definition name="functionName"
code operation=references name="className"
code operation=symbols path="src/module.ex"
code operation=call_graph name="handler"
code operation=search pattern="auth*" kind=function

# Terminal (with new options)
terminal command="npm test" cwd="/app/frontend"
terminal command="echo $VAR" env={"VAR": "value"} shell="bash"

# Diagnostics (via code tool - BETTER THAN terminal for errors!)
code operation=diagnose path="/app/src"
code operation=lint path="..."
code operation=typecheck path="..."

# Composite Tools (via meta tool - ONE CALL = multiple operations)
meta operation=analyze_file path="src/module.ex"           # File + symbols + diagnostics + knowledge
meta operation=debug_error message="undefined function"     # Memory + symbols + diagnostics
meta operation=suggest_next_tool task="implement auth"      # Workflow guidance

# Emergence (via cognitive tool - SPEC-044 Pattern Detection)
cognitive operation=emergence_dashboard              # Full metrics and status
cognitive operation=emergence_detect                 # Run pattern detection
cognitive operation=emergence_cycle                  # Full emergence cycle (detect → evaluate → alert)
cognitive operation=emergence_alerts                 # Patterns needing attention
cognitive operation=emergence_suggest topic="..."   # Pattern suggestions for task
cognitive operation=emergence_promote pattern_id="..." # Promote validated pattern to capability
cognitive operation=emergence_list                   # List patterns by status
cognitive operation=emergence_search query="..."     # Search patterns

# Reflector (via cognitive tool - SPEC-043 Metacognitive Self-Reflection)
cognitive operation=reflector_reflect content="..." task="..."  # Deep reflection on response
cognitive operation=reflector_evaluate content="..."            # Quick quality evaluation
cognitive operation=reflector_confidence content="..."          # Calibrated confidence assessment
cognitive operation=reflector_errors content="..."              # Analyze potential errors/biases

# Reasoning (SPEC-035 Unified Reasoning Engine)
reason operation=guided problem="..." strategy=auto  # Start session
reason operation=step session_id="..." thought="..." # Add step
reason operation=branch session_id="..." thought="..." # ToT branch
reason operation=backtrack session_id="..."          # Go back
reason operation=verify thoughts=["...", "..."]      # Check logic
reason operation=conclude session_id="..."           # Finish
reason operation=reflect session_id="..." success=true result="..."

# Library (via code tool - USE FIRST for package docs!)
code operation=library_discover path="/app"
code operation=library_get name="phoenix" ecosystem=hex
code operation=library_search query="json parser" ecosystem=npm

# Web (only after library lookup)
web operation=search query="..."
web operation=fetch url="..." format=markdown
web operation=blink url="..."

# Knowledge Graph
knowledge operation=query query="..."
knowledge operation=teach text="A depends on B"
knowledge operation=link path="/project/src"
knowledge operation=traverse node_name="..." max_depth=2

# Procedures
run_procedure name="deploy_staging" context={...}
run_procedure name="backup" async=true
run_procedure operation=status execution_id="abc123"
list_procedures
```

---

## 📖 Further Reading

- [README.md](README.md) - Full setup and deployment guide
- [VISION.md](VISION.md) - Architectural vision and roadmap
- [docs/specs/](docs/specs/) - Detailed implementation specifications
- [CHANGELOG.md](CHANGELOG.md) - Version history and features

---

**Mimo: Where Agents Remember.**
