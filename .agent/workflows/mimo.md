---
description: Mimo integration workflow - use Mimo tools correctly
---

# Mimo Workflow

> **Full documentation:** See [AGENTS.md](../../AGENTS.md) for comprehensive guide.

---

## Pre-Action Gate

Before `file edit` or `terminal`:
```
□ cognitive operation=assess completed?
□ memory operation=search completed?
□ Have 2+ step plan?
```

---

## 5-Phase Flow

```
PHASE 0 → PHASE 1 → PHASE 2 → PHASE 3 → PHASE 4
 REASON   CONTEXT  INTELLIGENCE ACTION   LEARNING
  (10%)   (15-20%)  (15-20%)   (45-55%)  (10-15%)
```

| Phase | Key Tools |
|-------|-----------|
| 0: Reason | `cognitive assess`, `reason guided`, `think plan` |
| 1: Context | `memory search`, `prepare_context` |
| 2: Intelligence | `code definition`, `code diagnose`, `code library_get` |
| 3: Action | `file edit`, `terminal` |
| 4: Learn | `memory store`, `reason reflect` |

---

## Quick Commands

```bash
# Session start
ask_mimo query="What context exists about this project?"
onboard path="."

# Before action
cognitive operation=assess topic="[task]"
memory operation=search query="[topic]"

# Smart tools (not brute force)
code operation=definition name="func"    # NOT file search
code operation=diagnose path="/project"  # NOT terminal compile

# After task
memory operation=store content="[insight]" category=fact importance=0.7
```

---

**Order: THINK → CONTEXT → INTELLIGENCE → ACTION → LEARN**
