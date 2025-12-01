# Mimo Agent Integration Guide

A comprehensive guide for AI agents to optimally leverage Mimo's cognitive infrastructure.

## 🧠 What is Mimo?

Mimo is a **Memory Operating System** for AI agents—not just another MCP server with tools. It provides:

- **Persistent Memory**: Remember across sessions via episodic, semantic, and procedural stores
- **Cognitive Infrastructure**: Working memory, consolidation, forgetting, and hybrid retrieval
- **24 Native Tools**: 9 internal memory tools + 15 core capability tools
- **Knowledge Graph**: Store and traverse relationships between entities
- **Procedural Execution**: Deterministic state machine workflows

---

## ⚠️ CRITICAL: You Have Full Development Capabilities

**DO NOT ask users to enable tools or say you cannot edit files/run commands!**

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
│  ✓ memory operation=search query="[topic]"                     │
│  ✓ ask_mimo query="What do I know about [topic]?"              │
│  ✓ knowledge operation=query query="[relationships]"           │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 2: INTELLIGENCE (Use smart tools, not brute force)      │
│  ─────────────────────────────────────────────────────────────  │
│  ✓ code_symbols operation=definition name="functionName"       │
│  ✓ code_symbols operation=references name="className"          │
│  ✓ diagnostics operation=all path="/project"                   │
│  ✓ library operation=get name="package" ecosystem=hex          │
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
| **Context** | memory, ask_mimo, knowledge | 15-20% | Check what you already know |
| **Intelligence** | code_symbols, diagnostics, library, cognitive | 15-20% | Smart analysis before action |
| **Action** | file, terminal | 45-55% | Execute changes |
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
// DO: code_symbols operation=definition name="functionName"
```

**BEFORE running compile/test for errors:**
```json
// DON'T: terminal command="mix compile"
// DO: diagnostics operation=all path="/project"
```

**BEFORE web search for package docs:**
```json
// DON'T: search query="phoenix documentation"
// DO: library operation=get name="phoenix" ecosystem=hex
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
| `file operation=read` immediately | `memory operation=search` first | May already know |
| `file operation=search pattern="func"` | `code_symbols operation=definition` | Semantic, 10x faster |
| `terminal command="mix compile"` | `diagnostics operation=all` | Structured output |
| `fetch url="hexdocs..."` | `library operation=get` | Cached locally |
| Reading same file repeatedly | Store facts in memory after first read | Build knowledge base |
| Skip after discoveries | `memory store` + `knowledge teach` | Knowledge compounds |

---

## 🛠️ Tool Reference

### Memory Tools (Internal)

These tools interact with Mimo's cognitive memory systems.

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `ask_mimo` | Strategic memory consultation (auto-records conversations) | `query` |
| `memory` | **Unified memory operations** (preferred) | `operation`, `content`, `query`, etc. |
| `store_fact` | Store facts (deprecated, use `memory`) | `content`, `category`, `importance` |
| `search_vibes` | Semantic search (deprecated, use `memory`) | `query`, `limit`, `threshold` |
| `ingest` | Bulk ingest files into memory | `path`, `strategy`, `category` |
| `run_procedure` | Execute registered procedures | `name`, `version`, `context` |
| `procedure_status` | Check procedure execution status | `execution_id` |
| `list_procedures` | List available procedures | — |
| `mimo_reload_skills` | Hot-reload skills configuration | — |

### Core Capability Tools (Mimo.Tools)

These are native Elixir implementations with zero external dependencies.

| Tool | Operations | Use Case |
|------|------------|----------|
| `file` | read, write, ls, search, replace_string, edit, list_symbols, read_symbol, glob, multi_replace, diff, etc. | All file system operations |
| `terminal` | execute, start_process, read_output, interact, kill | Command execution (supports cwd, env, shell options) |
| `fetch` | text, html, json, markdown, raw + image analysis | HTTP requests |
| `think` | thought, plan, sequential | Cognitive reasoning |
| `search` | web, code, images (with optional vision analysis) | Web search via DuckDuckGo/Bing/Brave |
| `knowledge` | query, teach | Knowledge graph operations |
| `blink` | fetch, analyze, smart | HTTP-level bot detection bypass |
| `browser` | fetch, screenshot, pdf, evaluate, interact, test | Full Puppeteer browser automation |
| `web_parse` | html → markdown | HTML conversion |
| `web_extract` | URL → clean content | Content extraction (Readability-style) |
| `sonar` | accessibility scan + optional vision | UI accessibility scanning |
| `vision` | image → analysis | Multimodal image analysis |
| `code_symbols` | parse, symbols, references, search, definition, call_graph | Code structure analysis |
| `library` | get, search, ensure, discover | Package documentation lookup |
| `diagnostics` | check, lint, typecheck, all | Compile/lint errors for Elixir, Python, JS/TS, Rust |
| `graph` | query, traverse, explore, node, path, stats, link | Synapse Web knowledge graph |

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
  "tool": "procedure_status",
  "arguments": {"execution_id": "abc123"}
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
  "tool": "code_symbols",
  "arguments": {
    "operation": "symbols",
    "path": "/workspace/project/src/auth.ts"
  }
}

// Find symbol definition
{
  "tool": "code_symbols",
  "arguments": {
    "operation": "definition",
    "name": "authenticateUser"
  }
}

// Get call graph
{
  "tool": "code_symbols",
  "arguments": {
    "operation": "call_graph",
    "name": "handleRequest"
  }
}

// Search symbols by pattern
{
  "tool": "code_symbols",
  "arguments": {
    "operation": "search",
    "pattern": "auth*",
    "kind": "function"
  }
}
```

### Synapse Web Graph

The knowledge graph connects code, concepts, and memories:

```json
// Query the graph
{
  "tool": "graph",
  "arguments": {
    "operation": "query",
    "query": "authentication patterns"
  }
}

// Traverse from a node
{
  "tool": "graph",
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
  "tool": "graph",
  "arguments": {
    "operation": "path",
    "from_node": "login_handler",
    "to_node": "database_connection"
  }
}

// Link code to graph
{
  "tool": "graph",
  "arguments": {
    "operation": "link",
    "path": "/workspace/project/src/"
  }
}
```

---

## 📦 Library Documentation

```json
// Get package info
{
  "tool": "library",
  "arguments": {
    "operation": "get",
    "name": "phoenix",
    "ecosystem": "hex"
  }
}

// Search packages
{
  "tool": "library",
  "arguments": {
    "operation": "search",
    "query": "json parser",
    "ecosystem": "npm",
    "limit": 5
  }
}

// Ensure package is cached
{
  "tool": "library",
  "arguments": {
    "operation": "ensure",
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
- **Code symbols** → enables `code_symbols` for precise navigation
- **Dependencies** → enables `library` for instant package docs  
- **Knowledge graph** → enables `knowledge` for relationship queries

### Step 3: Then Proceed with Task
Now all Mimo tools work at full capacity!

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
        │   └─► code_symbols operation=definition name="symbolName"
        │
        ├─► All USAGES of a symbol
        │   └─► code_symbols operation=references name="symbolName"
        │
        ├─► List ALL symbols in a file
        │   └─► code_symbols operation=symbols path="file.ts"
        │
        ├─► CALL relationships
        │   └─► code_symbols operation=call_graph name="functionName"
        │
        └─► Text/pattern search (non-code, comments, strings)
            └─► file operation=search path="." pattern="TODO"
```

### 🎯 code_symbols vs file search

| Use `code_symbols` when... | Use `file search` when... |
|---------------------------|--------------------------|
| Finding where a function is defined | Searching for text in comments |
| Finding all references to a class | Finding TODOs or FIXMEs |
| Understanding call relationships | Searching for string literals |
| Listing functions in a module | Pattern matching across files |
| Navigating by symbol name | Grep-style text search |

**Rule of thumb:** If it's a code construct (function, class, variable), use `code_symbols`. If it's text content, use `file search`.

### Finding Relationships?

```
Need to understand relationships?
        │
        ▼
What kind of relationship?
        │
        ├─► Code dependencies (imports, calls)
        │   └─► knowledge operation=query query="what depends on X?"
        │   └─► code_symbols operation=call_graph name="X"
        │
        ├─► Architecture/service relationships
        │   └─► knowledge operation=query query="..."
        │   └─► knowledge operation=traverse node_name="ServiceX"
        │
        └─► Package dependencies
            └─► library operation=discover path="."
            └─► knowledge operation=sync_dependencies
```

### Finding Package Documentation?

```
Need package/library docs?
        │
        ▼
Use library FIRST (faster, cached)
        │
        └─► library operation=get name="package" ecosystem=npm/pypi/hex/crates
        │
        ▼
Not found in library?
        │
        └─► search query="package documentation" operation=web
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

### 5. Package Documentation Lookup (Library-First!)

**IMPORTANT: Always check `library` before using `search`/`fetch` for package documentation!**

The `library` tool caches package docs locally and now searches external package registries (Hex, NPM, PyPI, crates.io) when cache is empty.

```json
// FIRST: Search library for package docs
{
  "tool": "library",
  "arguments": {
    "operation": "search",
    "query": "json parser",
    "ecosystem": "npm"
  }
}
// Returns packages from NPM registry with caching

// Get specific package documentation
{
  "tool": "library",
  "arguments": {
    "operation": "get",
    "name": "phoenix",
    "ecosystem": "hex"
  }
}

// Auto-discover and cache all project dependencies
{
  "tool": "library",
  "arguments": {
    "operation": "discover",
    "path": "/workspace/project"
  }
}
```

**Only use web `search`/`fetch` when:**
- Library tool doesn't have the package
- You need blog posts, tutorials, or Stack Overflow answers
- You need documentation not in package registries

### 6. Web Research (After Library Lookup)

```json
// Search the web
{
  "tool": "search",
  "arguments": {
    "query": "Next.js 14 app router best practices",
    "operation": "web",
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
  "tool": "graph",
  "arguments": {"operation": "stats"}
}
```

### Library Cache Stats

```json
{
  "tool": "library",
  "arguments": {"operation": "stats"}
}
```

---

## 🚀 Quick Reference Card

### Most Used Commands

```
# Session Start (MANDATORY)
ask_mimo query="What context do you have about this project?"
onboard path="." force=false

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
code_symbols operation=definition name="functionName"
code_symbols operation=references name="className"
code_symbols operation=symbols path="src/module.ex"
code_symbols operation=call_graph name="handler"
code_symbols operation=search pattern="auth*" kind=function

# Terminal (with new options)
terminal command="npm test" cwd="/app/frontend"
terminal command="echo $VAR" env={"VAR": "value"} shell="bash"

# Diagnostics (BETTER THAN terminal for errors!)
diagnostics operation=all path="/app/src"
diagnostics operation=lint path="..." language=python

# Library (USE FIRST for package docs!)
library operation=discover path="/app"
library operation=get name="phoenix" ecosystem=hex
library operation=search query="json parser" ecosystem=npm

# Web (only after library lookup)
search query="..." operation=web
fetch url="..." format=markdown
blink url="..." operation=smart

# Knowledge Graph
knowledge operation=query query="..."
knowledge operation=teach text="A depends on B"
knowledge operation=link path="/project/src"
knowledge operation=traverse node_name="..." max_depth=2
```

---

## 📖 Further Reading

- [README.md](README.md) - Full setup and deployment guide
- [VISION.md](VISION.md) - Architectural vision and roadmap
- [docs/specs/](docs/specs/) - Detailed implementation specifications
- [CHANGELOG.md](CHANGELOG.md) - Version history and features

---

**Mimo: Where Agents Remember.**
