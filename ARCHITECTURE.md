# Mimo Architecture: Tools, Skills, and the Cognitive Stack

> This document clarifies the architecture of Mimo and defines the relationship between Tools, Skills, and Dispatchers.

---

## Quick Reference

| Layer | What Is It | Where Defined | Example |
|-------|-----------|---------------|---------|
| **Tools** | MCP-exposed interfaces | `lib/mimo/tools/definitions.ex` | `memory`, `file`, `code` |
| **Dispatchers** | Routing logic | `lib/mimo/tools/dispatchers/*.ex` | `memory.ex`, `file.ex` |
| **Skills** | Elixir implementations | `lib/mimo/skills/*.ex` | `Terminal`, `FileOps`, `Web` |

---

## The Three Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AI AGENT (Claude/GPT/Gemini)                        │
│                         "What can I call?"                                  │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ MCP Protocol (JSON-RPC)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              TOOLS LAYER                                    │
│                                                                             │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│   │ memory  │  │  code   │  │  file   │  │terminal │  │   web   │  ...    │
│   └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘         │
│                                                                             │
│   Defined in: lib/mimo/tools/definitions.ex                                 │
│   Purpose: JSON Schema definitions exposed to MCP clients                   │
│   Count: 14 core tools (consolidated from 36+)                              │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ dispatch(tool_name, operation, args)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DISPATCHERS LAYER                                 │
│                                                                             │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│   │ memory.ex    │  │  code.ex     │  │  file.ex     │  │ terminal.ex  │   │
│   │ Routes to:   │  │ Routes to:   │  │ Routes to:   │  │ Routes to:   │   │
│   │ - SemanticMem│  │ - CodeSymbols│  │ - FileOps    │  │ - Terminal   │   │
│   │ - Knowledge  │  │ - Library    │  │ - ReadCache  │  │ - ProcessMgr │   │
│   │ - AskMimo    │  │ - Diagnostics│  │              │  │              │   │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘   │
│                                                                             │
│   Defined in: lib/mimo/tools/dispatchers/                                   │
│   Purpose: Route operations to appropriate skill modules                    │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ function calls
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            SKILLS LAYER                                     │
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │                     PURE ELIXIR IMPLEMENTATIONS                      │  │
│   │                                                                      │  │
│   │  • Terminal.ex      - Shell execution, process management            │  │
│   │  • FileOps.ex       - File read/write/edit with sandboxing           │  │
│   │  • Web.ex           - HTTP fetch with format conversion              │  │
│   │  • Browser.ex       - Puppeteer automation                           │  │
│   │  • Blink.ex         - HTTP-level browser emulation                   │  │
│   │  • Cognition.ex     - Epistemic assessment, meta-cognition           │  │
│   │  • Verify.ex        - Executable verification (math, logic)          │  │
│   │  • Diagnostics.ex   - Multi-language error detection                 │  │
│   │  ...                                                                 │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Defined in: lib/mimo/skills/                                              │
│   Purpose: Actual implementation logic, hot-reloadable                      │
│   Note: All external NPX skills removed - 100% native Elixir                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Tools vs Skills: No Overlap

**They are complementary layers, not competing concepts!**

| Aspect | Tools | Skills |
|--------|-------|--------|
| **Layer** | Interface | Implementation |
| **Protocol** | MCP JSON Schema | Elixir functions |
| **Consumer** | AI Agents | Dispatchers |
| **Stability** | Stable (public API) | Can change (internal) |
| **Hot-reload** | No (static definitions) | Yes (via SkillsSupervisor) |
| **Count** | 14 exposed | 20+ modules |

### Example Flow

When an agent calls `terminal command="ls -la"`:

1. **Tool Layer**: `terminal` tool definition validates the JSON schema
2. **Dispatcher**: `lib/mimo/tools/dispatchers/terminal.ex` receives the call
3. **Skill**: `Mimo.Skills.Terminal.execute/1` performs the actual shell execution
4. **Response**: Result flows back up through the layers

---

## The 14 Core Tools (v2.9.0)

| Tool | Purpose | Primary Skill(s) |
|------|---------|------------------|
| `memory` | Persistent memory + knowledge | SemanticMemory, Knowledge, AskMimo |
| `reason` | Structured reasoning | Reasoning, Amplifier |
| `code` | Code intelligence | CodeSymbols, Library, Diagnostics |
| `file` | File operations | FileOps, FileReadCache |
| `terminal` | Shell execution | Terminal, ProcessManager |
| `web` | Web operations | Web, Browser, Blink, Vision |
| `meta` | Composite operations | (orchestrates other tools) |
| `cognitive` | Meta-cognition | Cognition, Emergence, Reflector |
| `onboard` | Project initialization | (orchestrates indexing) |
| `autonomous` | Background tasks | AutonomousRunner |
| `orchestrate` | Multi-tool orchestration | Orchestrator |
| `awakening_status` | Agent progression | Awakening |
| `tool_usage` | Analytics | ToolUsage |

### Deprecated Tools (Still Work Internally)

These tools are hidden from MCP but route to their replacements:

```elixir
# From definitions.ex @deprecated_tools
"ask_mimo" → memory operation=synthesize
"knowledge" → memory operation=graph  
"code_symbols" → code operation=symbols
"library" → code operation=library_get
"diagnostics" → code operation=diagnose
"think" → reason operation=thought
"fetch" → web operation=fetch
"browser" → web operation=browser
# ... etc
```

---

## Cognitive Architecture

Beyond tools and skills, Mimo has cognitive subsystems:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         COGNITIVE LAYER                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     MEMORY SYSTEMS                                  │   │
│   │   • Working Memory (ETS)     - Short-term context buffer            │   │
│   │   • Episodic Memory (SQLite) - Experiences with vector embeddings   │   │
│   │   • Semantic Memory (Triples)- Facts and relationships              │   │
│   │   • Procedural Memory (FSM)  - Stored procedures/workflows          │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     COGNITIVE PROCESSES                             │   │
│   │   • Memory Consolidation     - Working → Long-term transfer         │   │
│   │   • Forgetting & Decay       - Active-time based pruning            │   │
│   │   • Sleep Cycle              - Multi-stage consolidation            │   │
│   │   • Active Inference         - Proactive context pushing            │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     METACOGNITION                                   │   │
│   │   • Reflector                - Self-evaluation and calibration      │   │
│   │   • Emergence                - Pattern detection and promotion      │   │
│   │   • Confidence Estimation    - Epistemic uncertainty tracking       │   │
│   │   • Feedback Loop            - Learning from outcomes               │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
lib/mimo/
├── tools/
│   ├── definitions.ex          # All 14 tool definitions (JSON schemas)
│   └── dispatchers/            # Route tools → skills
│       ├── memory.ex
│       ├── code.ex
│       ├── file.ex
│       ├── terminal.ex
│       ├── web.ex
│       ├── meta.ex
│       ├── reason.ex
│       ├── cognitive.ex
│       ├── emergence.ex
│       ├── autonomous.ex
│       └── orchestrate.ex
│
├── skills/                      # Pure Elixir implementations
│   ├── terminal.ex
│   ├── file_ops.ex
│   ├── web.ex
│   ├── browser.ex
│   ├── blink.ex
│   ├── cognition.ex
│   ├── verify.ex
│   ├── diagnostics.ex
│   └── ...
│
├── memory/                      # Memory subsystems
│   ├── semantic.ex             # Vector-based episodic memory
│   ├── working.ex              # ETS short-term buffer
│   ├── consolidator.ex         # Working → Long-term
│   └── decay.ex                # Forgetting mechanism
│
├── knowledge/                   # Knowledge graph
│   ├── synapse/                # Graph database
│   └── refresher.ex            # Background maintenance
│
├── cognitive/                   # Metacognition
│   ├── emergence.ex
│   ├── reflector.ex
│   ├── feedback_loop.ex
│   └── meta_learner.ex
│
└── brain/                       # Higher cognition
    ├── reasoning.ex
    ├── amplifier.ex
    └── reflector/
```

---

## Evolution from Vision

### Three Pillars Assessment

| Pillar | Status | Implementation |
|--------|--------|----------------|
| **PERSISTENCE** "I remember" | ✅ Complete | Episodic + Semantic + Procedural memory |
| **SYNTHESIS** "I understand" | 🔄 70% | Knowledge graph, reasoning, feedback learning |
| **EMERGENCE** "I discover" | 🔄 45% | Pattern detection exists, true emergence pending |

### Human Memory Model Comparison

| Human Memory Type | Mimo Equivalent | Status |
|-------------------|-----------------|--------|
| Working Memory | ETS Buffer | ✅ |
| Episodic Memory | SQLite + Vectors | ✅ |
| Semantic Memory | Knowledge Graph | ✅ |
| Procedural Memory | FSM Workflows | ✅ |
| Sleep Consolidation | Sleep Cycle | ✅ |
| Forgetting/Decay | Active-time Decay | ✅ |
| Emotional Tagging | (importance score) | 🔄 Partial |
| Priming/Association | Knowledge Graph | 🔄 Partial |
| Metacognition | Reflector + Confidence | ✅ |

**Overall: ~65-70% toward the "human memory and beyond" vision**

---

## Summary

1. **Tools** = What AI agents see (MCP interface, 14 exposed)
2. **Skills** = How it works (Elixir implementation, 20+ modules)
3. **Dispatchers** = The bridge (routing logic)

**No overlap. No conflict. Clean layered architecture.**

The confusion was terminological, not architectural. This document serves as the canonical reference.
