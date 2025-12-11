---
description: Mimo integration workflow - use Mimo tools correctly
---

# Mimo Workflow

> [!CAUTION]
> **HARD RULE**: You MUST complete Phases 0-2 BEFORE any file edits or terminal commands.
> Skipping phases is a FAILURE, not an optimization.

---

## 🛑 PRE-ACTION CHECKLIST (Must Complete Before Phase 3)

```
□ cognitive operation=assess → Got confidence score?
□ If confidence < 0.8: reason operation=guided completed?
□ memory operation=search → Checked existing knowledge?
□ Have explicit plan with 2+ steps?
```

**If ANY box is unchecked → STOP and complete it first.**

---

## PHASE 0: AUTO-REASONING (MANDATORY - Every Task)

> [!IMPORTANT]
> This phase is REQUIRED even for tasks that seem trivial.

```bash
# 1. ALWAYS assess confidence first - no exceptions
cognitive operation=assess topic="[user request]"

# 2. Check the returned confidence score:
#    If confidence < 0.8 OR task affects multiple files OR is complex:
reason operation=guided problem="[request]" strategy=auto

# 3. Even for simple tasks, create explicit plan:
think operation=plan steps=["step1", "step2", "step3"]
```

### Minimum Steps by Task Type

| Task Type | Minimum Steps |
|-----------|---------------|
| Single file edit | 2 steps |
| Multi-file change | 3+ steps |
| New feature | 5+ steps |
| Bug fix | 3+ steps |

---

## PHASE 1: CONTEXT (Before Any File/Terminal)

> [!WARNING]
> If you call `file operation=read` before `memory operation=search`, you are violating protocol.

```bash
# FIRST: Check what you already know
memory operation=search query="[topic]"

# For complex tasks, get comprehensive context:
meta operation=prepare_context query="[task]"

# Or ask Mimo strategically:
ask_mimo query="What do I know about [topic]?"
```

---

## PHASE 2: INTELLIGENCE (Smart Analysis - NOT Brute Force)

```bash
# Find definitions (NOT file search)
code operation=definition name="functionName"

# Find references
code operation=references name="className"

# Get diagnostics (NOT terminal compile)
code operation=diagnose path="/project"

# Get library docs (NOT web search)
code operation=library_get name="phoenix" ecosystem=hex
```

---

## PHASE 3: ACTION (ONLY After Phases 0-2)

```bash
file operation=read path="..."
file operation=edit path="..." old_str="..." new_str="..."
terminal command="..." cwd="..."
```

---

## PHASE 4: LEARNING (MANDATORY - End Every Task)

```bash
# Store insights from this task
memory operation=store content="[key insight]" category=fact importance=0.7

# Teach relationships discovered
knowledge operation=teach text="[relationship found]"

# Reflect on reasoning sessions
reason operation=reflect session_id="..." success=true result="[what worked]"
```

---

## Target Tool Distribution

| Phase | Target % | Tools |
|-------|----------|-------|
| 0: Reasoning | 10% | cognitive, reason, think |
| 1: Context | 15-20% | memory, ask_mimo, prepare_context |
| 2: Intelligence | 15-20% | code (definition, references, diagnose, library) |
| 3: Action | 45-55% | file, terminal, web |
| 4: Learning | 10-15% | memory store, knowledge teach, reflect |

---

## ❌ Anti-Patterns (Violations Require Reflection)

| ❌ Violation | ✅ Correct Approach | Penalty |
|--------------|---------------------|---------|
| Jump to file edit immediately | `cognitive operation=assess` first | Must reflect on failure |
| `file operation=read` before memory | `memory operation=search` first | Start over from Phase 0 |
| `file operation=search pattern="func"` | `code operation=definition name="func"` | Use smarter tool |
| `terminal command="mix compile"` for errors | `code operation=diagnose path="."` | Use diagnostic tool |
| `web operation=search query="phoenix docs"` | `code operation=library_get name="phoenix"` | Use cached library |
| Skip storing discoveries | `memory operation=store` | Knowledge lost forever |
| Skip Phase 0 "because it's simple" | Still assess and plan | No task is too simple |

### If You Violate a Rule

```bash
# IMMEDIATELY call:
reason operation=reflect session_id="..." success=false error="Skipped [phase], jumped to [action]"

# Then restart from Phase 0
```

---

## 🔒 Summary

> [!CAUTION]
> **The order is: THINK → CONTEXT → INTELLIGENCE → ACTION → LEARN**
>
> A 10-second assessment saves 10-minute rollbacks.
