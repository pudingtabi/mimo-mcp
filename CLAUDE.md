# Claude Code + Mimo Integration Guide

> **Mimo-First Approach**: Always use Mimo MCP tools first, Claude built-in tools as fallbacks.

This guide is for **Claude Code CLI** users. For GitHub Copilot, see [AGENTS.md](AGENTS.md).

---

## Tool Priority Order

| Need | Mimo Tool (FIRST) | Claude Fallback (SECOND) |
|------|-------------------|--------------------------|
| Read file | `mcp__mimo__file operation=read` | `Read` |
| Edit file | `mcp__mimo__file operation=edit` | `Edit` |
| Search code | `mcp__mimo__code operation=definition` | `Grep` |
| Find files | `mcp__mimo__file operation=glob` | `Glob` |
| Run command | `mcp__mimo__terminal command="..."` | `Bash` |
| Web search | `mcp__mimo__web operation=search` | `WebSearch` |

**Why Mimo first?**
- Automatic memory context injection
- Pattern learning from past operations
- Knowledge graph integration
- Persistent wisdom across sessions

---

## Session Start Protocol

```bash
# 1. Query accumulated wisdom (ALWAYS FIRST)
mcp__mimo__ask_mimo query="What context do you have about this project?"

# 2. Check awakening status
mcp__mimo__awakening_status include_achievements=true

# 3. Index project if needed
mcp__mimo__onboard path="." force=false
```

---

## Cognitive Excellence Protocol

### Before Any Complex Task

```bash
# Step 1: Assess confidence
mcp__mimo__cognitive operation=assess topic="[your task]"

# Step 2: Search existing knowledge
mcp__mimo__memory operation=search query="[relevant topic]"

# Step 3: Start reasoning session (if complex)
mcp__mimo__reason operation=guided problem="[task description]" strategy=auto
```

### Reasoning Strategies

| Task Type | Strategy | When |
|-----------|----------|------|
| Sequential logic | `cot` | Math, debugging, step-by-step |
| Multiple approaches | `tot` | Design decisions, architecture |
| Needs tool execution | `react` | Find & fix bugs, implementation |
| Learning from errors | `reflexion` | Post-mortems, retries |

---

## Verification (MANDATORY for Claims)

Never say "I'm confident" without verification:

```bash
# Verify counts
mcp__mimo__cognitive operation=verify_count topic="number of errors"

# Verify logic
mcp__mimo__cognitive operation=verify_logic topic="does A imply B?"

# Verify math
mcp__mimo__cognitive operation=verify_math topic="calculation check"

# Self-check for overconfidence
mcp__mimo__cognitive operation=verify_self_check topic="am I too confident?"
```

---

## Memory System

### Store Discoveries IMMEDIATELY

```bash
# Store facts (technical details)
mcp__mimo__memory operation=store content="[discovery]" category=fact importance=0.8

# Store actions (completed work)
mcp__mimo__memory operation=store content="[what was done]" category=action importance=0.7

# Store observations (patterns noticed)
mcp__mimo__memory operation=store content="[observation]" category=observation importance=0.6

# Store plans (future work)
mcp__mimo__memory operation=store content="[plan]" category=plan importance=0.7
```

### Search Before Reading Files

```bash
# ALWAYS search memory first - you may already know!
mcp__mimo__memory operation=search query="[topic]" limit=10

# If not in memory, THEN read file
mcp__mimo__file operation=read path="..."
```

---

## Knowledge Graph

For **relationships** between entities:

```bash
# Query relationships
mcp__mimo__knowledge operation=query query="what depends on X?"

# Teach new relationships
mcp__mimo__knowledge operation=teach subject="auth.ex" predicate="imports" object="crypto"

# Traverse connections
mcp__mimo__knowledge operation=traverse node_id="module:auth" direction=outgoing
```

---

## Code Intelligence

```bash
# Find definition (NOT grep!)
mcp__mimo__code operation=definition name="function_name"

# Find all usages
mcp__mimo__code operation=references name="ClassName"

# List symbols in file
mcp__mimo__code operation=symbols path="lib/auth.ex"

# Run diagnostics (NOT terminal compile!)
mcp__mimo__code operation=diagnose path="lib/"

# Get library docs (NOT web search!)
mcp__mimo__code operation=library_get name="phoenix" ecosystem=hex
```

---

## When to Use Claude Built-in Tools

Use Claude's built-in tools when:

1. **Mimo MCP is unavailable** - Connection issues
2. **Performance critical** - Simple operations where MCP overhead matters
3. **Mimo tool fails** - Fallback after error
4. **Explicit user request** - User asks for specific tool

### Fallback Pattern

```
Try Mimo tool
  → Success? Done
  → Failed? Log to memory, use Claude fallback
```

---

## Anti-Patterns

| DON'T | DO |
|-------|-----|
| Jump to `Edit` immediately | `cognitive assess` + `reason guided` first |
| `Read` before memory search | `memory search` first |
| `Grep` for function location | `code definition name="func"` |
| `Bash "mix compile"` for errors | `code diagnose path="..."` |
| `WebSearch` for package docs | `code library_get` |
| Forget to store discoveries | `memory store` after every insight |
| Claim confidence without proof | `cognitive verify_*` first |

---

## Claude-Specific Features

### Use TodoWrite for Complex Tasks

```
TodoWrite with todos showing:
- What needs to be done
- Current progress (in_progress, pending, completed)
```

### Use Task for Parallel Work

```
Task tool with subagent_type for:
- Explore: Codebase exploration
- Plan: Implementation planning
- claude-code-guide: Documentation lookup
```

---

## Quick Reference

```
SESSION START:
  ask_mimo → awakening_status → onboard

BEFORE ACTION:
  cognitive assess → memory search → reason guided (if complex)

DURING WORK:
  Mimo tools first → Claude fallback if needed

AFTER DISCOVERY:
  memory store → knowledge teach

BEFORE CLAIMING:
  cognitive verify_* → only then claim confidence
```

---

## Environment Setup

Ensure Mimo MCP is connected:

```json
{
  "mcpServers": {
    "mimo": {
      "command": "/path/to/mimo-mcp/bin/mimo-mcp-stdio"
    }
  }
}
```

**Order: CONTEXT → REASON → ACT → LEARN → VERIFY**
