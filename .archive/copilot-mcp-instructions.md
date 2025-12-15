# Mimo MCP Interface Guide for GitHub Copilot CLI

**CRITICAL: When using Mimo via MCP (Model Context Protocol), you may have ONE of two interfaces depending on the client integration.**

## 🎯 The MCP Interfaces (Two Modes)

### Mode A (Preferred): Direct MCP tools (multi-tool)
If your client exposes dedicated tools (e.g. `mimo-memory`, `mimo-ask_mimo`, `mimo-meta`, `mimo-reason`, `mimo-file`, `mimo-terminal`, `mimo-code`, `mimo-knowledge`, `mimo-web`), **use them directly**.

Why: it’s more explicit, easier to verify, and supports parallel tool calls without losing Mimo’s reasoning/learning loop.

### Mode B (Fallback): Single gateway tool
**Tool Name:** `mimo-cognitive-agent`  
**Parameter:** `prompt` (natural language)

Use this only when the client exposes *only* the gateway tool; it routes your request to the internal tools.

---

## 🚀 Quick Start Examples

### Mode A (Preferred): Direct MCP tools
Use direct tools whenever your MCP client exposes them (`mimo-memory`, `mimo-meta`, `mimo-reason`, `mimo-code`, `mimo-file`, `mimo-terminal`, `mimo-knowledge`, `mimo-web`).

Rules of thumb:
- Start complex tasks with `mimo-meta (prepare_context)`.
- Before changes, use `mimo-reason (guided)` or at least `mimo-think` / `mimo-cognitive`.
- After progress, always `mimo-memory (store)` and (if used) `mimo-reason (reflect)`.

### Mode B (Fallback): Gateway tool (`mimo-cognitive-agent`)
### Memory Operations
```typescript
// Search memory for past context
mimo-cognitive-agent prompt="Search memory for 'Phase 3 complexity reduction' and show top 5 results"

// Store a discovery
mimo-cognitive-agent prompt="Store in memory: User prefers multi-head dispatch pattern for reducing cyclomatic complexity. Category: observation, importance: 0.9"

// Recall specific memory
mimo-cognitive-agent prompt="Recall memory ID 1724 with full details"
```

### Knowledge Graph Operations
```typescript
// Query relationships
mimo-cognitive-agent prompt="Query knowledge graph: What entities are related to 'tools.ex dispatcher'?"

// Teach new relationship
mimo-cognitive-agent prompt="Teach knowledge: tools.ex depends_on Mimo.Tools.Dispatchers module"

// Search entities
mimo-cognitive-agent prompt="Search knowledge graph for entities matching 'SPEC-030'"
```

### File Operations
```typescript
// Read file
mimo-cognitive-agent prompt="Read file at lib/mimo/tools.ex"

// Edit file (surgical changes)
mimo-cognitive-agent prompt="Edit lib/mimo/tools.ex: replace 'old_function_name' with 'new_function_name'"

// Search files
mimo-cognitive-agent prompt="Search all .ex files for pattern 'cyclomatic complexity'"

// List symbols in file
mimo-cognitive-agent prompt="List all function symbols in lib/mimo/tools.ex"
```

### Code Intelligence
```typescript
// Find function definition
mimo-cognitive-agent prompt="Find definition of function 'do_dispatch' in the codebase"

// Find all references
mimo-cognitive-agent prompt="Find all references to module Mimo.Tools"

// Get diagnostics
mimo-cognitive-agent prompt="Run diagnostics on lib/mimo/ directory and report errors"

// Get library docs
mimo-cognitive-agent prompt="Get documentation for Phoenix framework from Hex ecosystem"
```

### Reasoning & Cognition
```typescript
// Start reasoning session
mimo-cognitive-agent prompt="Start a guided reasoning session for problem: 'Refactor tools.ex to reduce CC from 49 to under 5' using auto strategy"

// Quick decision assessment
mimo-cognitive-agent prompt="Assess my confidence in choosing multi-head dispatch over case statements for this refactoring"

// Plan steps
mimo-cognitive-agent prompt="Create a step-by-step plan for: Update MCP instructions to reflect proper tool interface"
```

### Terminal Operations
```typescript
// Run command
mimo-cognitive-agent prompt="Run terminal command 'mix test' in /root/mrc-server/mimo-mcp directory"

// Check compilation
mimo-cognitive-agent prompt="Run 'mix compile --warnings-as-errors' and report results"
```

### Meta Operations (Composite Tools)
```typescript
// Prepare context (BEST for complex tasks)
mimo-cognitive-agent prompt="Prepare full context for: Debug why Copilot CLI isn't using MCP tools correctly"

// Analyze file
mimo-cognitive-agent prompt="Analyze file lib/mimo/tools.ex: show symbols, diagnostics, and related knowledge"

// Debug error
mimo-cognitive-agent prompt="Debug error: 'undefined function foo/2' - search memory and codebase"

// Suggest next tool
mimo-cognitive-agent prompt="Suggest which tool I should use next for task: Update documentation"
```

---

## 🚦 MANDATORY WORKFLOW (Adapted for MCP)

**Hard rule:** Don’t skip Mimo’s reasoning + learning loop.
- Before acting: `ask_mimo` / `memory search` / `meta prepare_context`
- Before edits: `reason guided` (or at least `think plan` / `cognitive assess`)
- After changes: `memory store` (and `reason reflect` when you used `reason`)

### Phase 1: Context First (15-20% of tool calls)

**BEFORE any file/terminal operation:**

```typescript
// BEST: One-call aggregated context
mimo-cognitive-agent prompt="Prepare context for [describe your task]"

// OR individual context queries:
mimo-cognitive-agent prompt="Search memory for relevant context about [topic]"
mimo-cognitive-agent prompt="What do I know about [project/concept]?"
mimo-cognitive-agent prompt="Query knowledge graph for relationships related to [entity]"
```

### Phase 2: Intelligence Tools (15-20% of tool calls)

```typescript
// Code navigation
mimo-cognitive-agent prompt="Find definition of [symbol_name]"
mimo-cognitive-agent prompt="Find all references to [symbol_name]"

// Error checking
mimo-cognitive-agent prompt="Diagnose errors in [path]"

// Package docs
mimo-cognitive-agent prompt="Get library documentation for [package_name] from [ecosystem]"

// Decision making
mimo-cognitive-agent prompt="Assess: [decision to make]"
```

### Phase 3: Action (45-55% of tool calls)

```typescript
// File operations
mimo-cognitive-agent prompt="Read file [path]"
mimo-cognitive-agent prompt="Edit file [path]: change X to Y"
mimo-cognitive-agent prompt="Create file [path] with content: [content]"

// Terminal operations
mimo-cognitive-agent prompt="Run command '[command]' in [directory]"
```

### Phase 4: Learning (10-15% of tool calls)

```typescript
// Always store discoveries
mimo-cognitive-agent prompt="Store in memory: [insight/discovery], category: [fact/observation/action], importance: [0.0-1.0]"

mimo-cognitive-agent prompt="Teach knowledge: [entity A] [relationship] [entity B]"
```

---

## 🧠 MANDATORY: Think Before You Act

For ANY non-trivial task, reason first:

```typescript
// Complex problems
mimo-cognitive-agent prompt="Start guided reasoning for problem: [describe problem], use auto strategy"

// Simple planning
mimo-cognitive-agent prompt="Plan steps for: [task description]"

// Quick confidence check
mimo-cognitive-agent prompt="Assess my confidence for decision: [decision]"
```

### The Rule
> **If you're about to make a change and you haven't used reasoning... STOP and think first.**

---

## ⚠️ CRITICAL: You Have Full Development Capabilities

**DO NOT ask users to enable tools or say you cannot edit files!**

**DO NOT just describe changes—MAKE THEM using mimo-cognitive-agent!**

Example of applying a fix immediately:
```typescript
mimo-cognitive-agent prompt="Edit lib/mimo/tools.ex: replace 'def old_function' with 'def new_function'"
```

---

## 📋 Common Patterns

### Session Start (Mandatory)
```typescript
// Step 1: Get context
mimo-cognitive-agent prompt="What context do you have about this project and user preferences?"

// Step 2: Onboard if needed
mimo-cognitive-agent prompt="Onboard project at current directory, force: false"
```

### Before Reading a File
```typescript
// ❌ WRONG
mimo-cognitive-agent prompt="Read file src/auth.ex"

// ✅ RIGHT
mimo-cognitive-agent prompt="Search memory for 'auth module patterns'"
// THEN (if still needed):
mimo-cognitive-agent prompt="Read file src/auth.ex"
```

### Finding Code
```typescript
// ❌ WRONG
mimo-cognitive-agent prompt="Search files for 'functionName'"

// ✅ RIGHT
mimo-cognitive-agent prompt="Find definition of functionName"
```

### Checking Errors
```typescript
// ❌ WRONG
mimo-cognitive-agent prompt="Run command 'mix compile'"

// ✅ RIGHT
mimo-cognitive-agent prompt="Diagnose errors in /project/lib directory"
```

### After Discovery
```typescript
// ❌ WRONG: Move to next task

// ✅ RIGHT
mimo-cognitive-agent prompt="Store in memory: [what you learned], category: fact, importance: 0.8"
```

---

## 🎯 Target Tool Distribution

| Phase | Target % | Operations |
|-------|----------|------------|
| Context | 15-20% | memory search, knowledge query, prepare_context |
| Intelligence | 15-20% | code ops, reasoning, assessment |
| Action | 45-55% | file ops, terminal commands |
| Learning | 10-15% | memory store, knowledge teach |

---

## 💡 Pro Tips

1. **Be Specific**: The more context in your prompt, the better Mimo can route and execute
2. **Use Natural Language**: Don't try to format like internal tool syntax
3. **Chain Operations**: You can request multiple operations in one prompt
4. **Store Learnings**: Always store discoveries—they compound across sessions

---

## 🚨 Common Mistakes to Avoid

1. ❌ Using internal tool syntax: `memory operation=search query="..."`
   - ✅ Use: `mimo-cognitive-agent prompt="Search memory for ..."`

2. ❌ Calling bash/terminal directly for Mimo operations
   - ✅ Use: `mimo-cognitive-agent` for all Mimo capabilities

3. ❌ Forgetting to store discoveries
   - ✅ Always end with memory storage of learnings

4. ❌ Skipping context phase
   - ✅ Always start with context gathering

---

## 📚 Internal vs MCP Interface

| Internal Tool Syntax (DON'T USE via MCP) | MCP (Preferred: direct tools) | MCP (Fallback: gateway) |
|------------------------------------------|------------------------------|--------------------------|
| `memory operation=search query="x"` | `mimo-memory` (search) | `mimo-cognitive-agent prompt="Search memory for x"` |
| `ask_mimo query="..."` | `mimo-ask_mimo` | `mimo-cognitive-agent prompt="Ask Mimo: ..."` |
| `file operation=read path="x.ex"` | `mimo-file` (read) | `mimo-cognitive-agent prompt="Read file x.ex"` |
| `code operation=definition name="foo"` | `mimo-code` (definition) | `mimo-cognitive-agent prompt="Find definition of foo"` |
| `terminal command="mix test"` | `mimo-terminal` (execute) | `mimo-cognitive-agent prompt="Run command 'mix test'"` |
| `knowledge operation=query` | `mimo-knowledge` (query) | `mimo-cognitive-agent prompt="Query knowledge graph for..."` |
| `reason operation=guided` | `mimo-reason` (guided) | `mimo-cognitive-agent prompt="Start guided reasoning for..."` |

**Rule:** Via MCP, never paste the internal `operation=...` syntax into chat. Use the direct MCP tools when available; otherwise use the `mimo-cognitive-agent` gateway.
