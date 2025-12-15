# MANDATORY: Mimo MCP Tool Usage

**HARD RULE: You MUST use Mimo tools. Claude built-in tools are FORBIDDEN unless Mimo fails.**

---

## FORBIDDEN ACTIONS

You MUST NOT do these. Violation breaks the user's workflow:

| FORBIDDEN | USE INSTEAD |
|-----------|-------------|
| `Grep` to find function/class | `mcp__mimo__file` with `find_definition` |
| `Grep` to find usages | `mcp__mimo__file` with `find_references` |
| `Glob` to find files | `mcp__mimo__file` with `glob` |
| `Read` to read files | `mcp__mimo__file` with `read` |
| `Edit` to edit files | `mcp__mimo__file` with `edit` |
| `Bash` to run commands | `mcp__mimo__terminal` with `command` |
| `WebSearch` for docs | `mcp__mimo__code` with `library_get` |

---

## COPY-PASTE EXAMPLES

Use these EXACT patterns. Copy and modify:

### Find where a function is defined
```
mcp__mimo__file operation="find_definition" name="authenticate"
```

### Find all usages of a function/class
```
mcp__mimo__file operation="find_references" name="UserController"
```

### List all functions in a file
```
mcp__mimo__file operation="symbols" path="lib/auth.ex"
```

### Read a file
```
mcp__mimo__file operation="read" path="lib/app.ex" limit=100
```

### Edit a file
```
mcp__mimo__file operation="edit" path="lib/app.ex" old_str="old text" new_str="new text"
```

### Find files by pattern
```
mcp__mimo__file operation="glob" pattern="**/*.ex"
```

### Search file content
```
mcp__mimo__file operation="search" path="lib/" pattern="TODO"
```

### Run a command
```
mcp__mimo__terminal command="mix test"
```

### Get package documentation
```
mcp__mimo__code operation="library_get" name="phoenix" ecosystem="hex"
```

### Get compiler errors
```
mcp__mimo__code operation="diagnose" path="lib/"
```

---

## TRIGGER RULES

When you think X, do Y:

| WHEN YOU THINK... | DO THIS |
|-------------------|---------|
| "Where is function X defined?" | `file find_definition name="X"` |
| "Who calls function X?" | `file find_references name="X"` |
| "What functions are in this file?" | `file symbols path="..."` |
| "I need to read this file" | `file read path="..."` |
| "I need to find files matching..." | `file glob pattern="..."` |
| "I need to search for text..." | `file search pattern="..."` |
| "I need to run a command" | `terminal command="..."` |
| "How do I use library X?" | `code library_get name="X"` |
| "Are there compile errors?" | `code diagnose path="..."` |
| "I should check memory first" | `memory search query="..."` |

---

## SESSION START (MANDATORY)

Run these FIRST in every session:

```
mcp__mimo__ask_mimo query="What context exists for this project?"
mcp__mimo__onboard path="."
```

---

## BEFORE YOU READ ANY FILE

ALWAYS search memory first. You may already know:

```
mcp__mimo__memory operation="search" query="relevant topic"
```

If found, skip the file read. If not found, read and then store:

```
mcp__mimo__memory operation="store" content="what you learned" category="fact" importance=0.8
```

---

## BEFORE COMPLEX TASKS

Start a reasoning session:

```
mcp__mimo__reason operation="guided" problem="describe the task"
```

---

## WHEN MIMO FAILS

Only if Mimo returns an error, you may ask user permission:

> "Mimo file tool failed with [error]. May I use Claude's Read tool as fallback?"

Wait for user approval before using built-in tools.

---

## WHY MIMO?

Mimo tools provide:
- **Memory context**: Past knowledge injected automatically
- **Symbol intelligence**: Faster than grep, understands code structure
- **Knowledge graph**: Relationships between entities
- **Learning**: Patterns improve over time

Claude built-ins have NONE of these. That's why Mimo first, always.

---

## QUICK REFERENCE

| Task | Mimo Tool | Operation |
|------|-----------|-----------|
| Read file | `file` | `read` |
| Edit file | `file` | `edit` |
| Find definition | `file` | `find_definition` |
| Find references | `file` | `find_references` |
| List symbols | `file` | `symbols` |
| Find files | `file` | `glob` |
| Search content | `file` | `search` |
| Run command | `terminal` | (just `command=`) |
| Package docs | `code` | `library_get` |
| Compiler errors | `code` | `diagnose` |
| Search memory | `memory` | `search` |
| Store memory | `memory` | `store` |
| Ask Mimo | `ask_mimo` | (just `query=`) |
| Start reasoning | `reason` | `guided` |
| Query knowledge | `knowledge` | `query` |

---

## ENFORCEMENT

If you use `Grep`, `Glob`, `Read`, `Edit`, `Bash`, or `WebSearch` without Mimo failing first, you are violating these instructions. The user has explicitly configured Mimo as the primary toolset. Respect this configuration.
