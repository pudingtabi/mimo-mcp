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

### 5. Web Research with Memory

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

# Terminal (with new options)
terminal command="npm test" cwd="/app/frontend"
terminal command="echo $VAR" env={"VAR": "value"} shell="bash"

# Web
search query="..." operation=web
fetch url="..." format=markdown
blink url="..." operation=smart

# Code
code_symbols operation=symbols path="..."
code_symbols operation=definition name="functionName"

# Diagnostics
diagnostics operation=all path="/app/src"
diagnostics operation=lint path="..." language=python

# Library
library operation=discover path="/app"
library operation=get name="phoenix" ecosystem=hex

# Knowledge
knowledge operation=query query="..."
knowledge operation=teach text="A depends on B"
graph operation=traverse node_name="..." max_depth=2
```

---

## 📖 Further Reading

- [README.md](README.md) - Full setup and deployment guide
- [VISION.md](VISION.md) - Architectural vision and roadmap
- [docs/specs/](docs/specs/) - Detailed implementation specifications
- [CHANGELOG.md](CHANGELOG.md) - Version history and features

---

**Mimo: Where Agents Remember.**
