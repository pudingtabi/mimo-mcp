---
trigger: always_on
---

# Antigravity + Mimo MCP Rules

**CRITICAL: These rules are MANDATORY. Violations require immediate correction.**

---

## 🛑 HARD GATES (Non-Negotiable)

> [!CAUTION]
> **NEVER** call `file operation=edit`, `terminal command=`, or any action tool UNTIL you have completed Phase 0 and Phase 1. No exceptions, even for "simple" tasks.

### Gate Checklist (Must Complete Before Action)

```
□ Called `cognitive operation=assess` → Got confidence score
□ If confidence < 0.8: Called `reason operation=guided`
□ Called `memory operation=search` → Checked existing knowledge
□ Have explicit plan (via `think` or `reason`)
```

**If ANY box is unchecked → STOP and complete it first.**

---

## 🎯 Core Philosophy

1. **Think before you act** — NEVER jump straight to editing. Assess FIRST.
2. **Write simple code** — Prefer readable over clever. Document WHY.
3. **Learn and store** — Persist discoveries so you don't repeat work.
4. **Verify before proceeding** — Check your work at each phase transition.

---

## ⚠️ You Have Full Capabilities

**Don't ask users to enable tools. Apply fixes directly using Mimo tools.**

---

## 🧠 PHASE 0: Reason First (MANDATORY - NO EXCEPTIONS)

> [!IMPORTANT]
> This phase is REQUIRED even for tasks that seem trivial. A 5-second assessment prevents 5-minute mistakes.

```bash
# Step 1: ALWAYS start here - no exceptions
cognitive operation=assess topic="[user request]"

# Step 2: Check the confidence score returned
# If confidence < 0.8 OR task has multiple steps OR affects multiple files:
reason operation=guided problem="[request]" strategy=auto

# Step 3: Even for simple tasks, create explicit plan:
think operation=plan steps=["step1", "step2", "step3"]
```

### Minimum Planning Requirements

| Task Type | Minimum Steps |
|-----------|---------------|
| Single file edit | 2 steps |
| Multi-file change | 3+ steps |
| New feature | 5+ steps |
| Bug fix | 3+ steps (investigate, fix, verify) |

---

## 🚦 Four-Phase Workflow (SEQUENTIAL - No Skipping)

```
PHASE 0 → PHASE 1 → PHASE 2 → PHASE 3 → PHASE 4
   ↓         ↓         ↓         ↓         ↓
 REASON   CONTEXT  INTELLIGENCE ACTION   LEARNING
  (10%)   (15-20%)  (15-20%)   (45-55%)  (10-15%)
```

### Phase 1: Context First (BEFORE reading ANY files)

```bash
# FIRST: Check what you already know
memory operation=search query="[topic]"

# For complex tasks, get comprehensive context:
meta operation=prepare_context query="[task]"

# Or ask Mimo strategically:
ask_mimo query="What context exists about [topic]?"
```

> [!WARNING]
> If you call `file operation=read` before `memory operation=search`, you are violating protocol.

### Phase 2: Intelligence (Smart Analysis - NOT Brute Force)

```bash
code operation=definition name="functionName"    # NOT file search
code operation=diagnose path="/project"          # NOT terminal compile
code operation=library_get name="pkg" ecosystem=hex  # NOT web search
```

### Phase 3: Action (ONLY after Phases 0-2 complete)

```bash
file operation=edit path="..." old_str="..." new_str="..."
terminal command="mix test" cwd="/project"
```

### Phase 4: Learning (MANDATORY after every task)

```bash
# Store insights from this task
memory operation=store content="[insight]" category=fact importance=0.7

# Reflect on reasoning effectiveness
reason operation=reflect session_id="..." success=true result="..."
```

---

## ❌ Anti-Patterns (Violations Require `reflect` with `success=false`)

| ❌ Violation | ✅ Correct Approach | Penalty |
|--------------|---------------------|---------|
| Jump to editing immediately | `cognitive operation=assess` first | Must reflect on failure |
| `file operation=read` before memory | `memory operation=search` first | Start over |
| `file operation=search pattern="func"` | `code operation=definition name="func"` | Use smarter tool |
| `terminal command="mix compile"` for errors | `code operation=diagnose` | Use diagnostic tool |
| `web operation=search query="phoenix docs"` | `code operation=library_get` | Use cached library |
| Skip storing discoveries | `memory operation=store` | Knowledge lost |
| Describe changes in prose | `file operation=edit` directly | Apply the fix |
| Skip Phase 0 "because it's simple" | Still assess and plan | No task is too simple |

### If You Violate a Rule

```bash
# IMMEDIATELY call:
reason operation=reflect session_id="..." success=false error="Skipped [phase], jumped to [action]"

# Then restart from Phase 0
```

---

## 🚀 Session Start (EVERY session)

```bash
# 1. Get existing context
ask_mimo query="What context do you have about this project?"

# 2. Ensure project is indexed
onboard path="." force=false
```

---

## 📚 Quick Reference

```bash
# Phase 0: Reasoning (MANDATORY)
cognitive operation=assess topic="..."
reason operation=guided problem="..." strategy=auto
think operation=plan steps=["..."]

# Phase 1: Context
memory operation=search query="..."
meta operation=prepare_context query="..."

# Phase 2: Intelligence  
code operation=definition name="functionName"
code operation=references name="className"
code operation=diagnose path="/project"

# Phase 3: Action
file operation=edit path="..." old_str="..." new_str="..."
terminal command="..." cwd="..."

# Phase 4: Learning
memory operation=store content="..." category=fact importance=0.7
reason operation=reflect session_id="..." success=true result="..."
```

---

## 🔒 Enforcement Summary

> [!CAUTION]
> **The order is: THINK → CONTEXT → INTELLIGENCE → ACTION → LEARN**
> 
> Skipping phases is a FAILURE, not an optimization.
> "Simple" tasks still require Phase 0 assessment.
> Every task ends with Phase 4 learning.

---

**REMEMBER: A 10-second assessment saves 10-minute rollbacks.**
