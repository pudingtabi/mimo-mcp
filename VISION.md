# MIMO V3.0: Enhanced AI Brain with Universal MCP Access

## Core Truth

**Mimo is an enhanced AI brain that persists across sessions, learns relationships, and executes procedures - made accessible to ANY AI via MCP.**

### Architecture Priority (Corrected)

```
┌─────────────────────────────────────────────────────┐
│           AI AGENTS (Claude, GPT, Custom)           │
│           CLI/IDE Integration Layer                 │
└──────────────────┬──────────────────────────────────┘
                   │ stdio/HTTP/WebSocket
                   ▼
┌─────────────────────────────────────────────────────┐
│         MCP PROTOCOL ADAPTERS (Universal)           │
│  • Stdio (primary - Claude/IDE)                     │
│  • HTTP/REST (secondary - API access)               │
│  • WebSocket (tertiary - real-time)                 │
└──────────────────┬──────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────┐
│            META-COGNITIVE ROUTER (Brain)            │
│   Classifies: "Is this about memory, tools, or both?"
└───────────┬────────────┬────────────────────────────┘
            │            │
            ▼            ▼
    ┌──────────────┐   ┌──────────────────┐
    │ TOOL LAYER   │   │ MEMORY LAYER     │
    │              │   │ (The Enhancement)│
    ├──────────────┤   ├──────────────────┤
    │ 5 built-ins  │   │ Episodic Store   │
    │ 37 external  │   │ Semantic Store   │ ← v3.0: Graph DB
    │              │   │ Procedural Store │ ← v3.0: Rule engine
    └──────────────┘   └──────────────────┘
```

## Critical Fixes Made

**The stdio MCP interface was broken - we fixed it:**

✅ Stdio now routes ALL tools (42 total) through ToolRegistry
✅ No more 5-tool limitation
✅ Lazy-spawning prevents ToolRegistry blocking
✅ Both internal and external skills accessible via Claude Desktop

## What This Enables

Any AI agent can now:

1. **Query persistent memory**: "What did we discuss about the auth service last week?"
2. **Execute tools**: "Fetch the API docs and take a screenshot"
3. **Learn relationships**: "The auth service depends on the user service" (stored in semantic store)
4. **Follow procedures**: "Deploy to staging" (executes procedural playbook)
5. **Remember across sessions**: Memory persists even when AI session ends

## Tools Available (42 Total)

### Built-in Tools (5) - Always Available, Zero Overhead
- `ask_mimo`, `search_vibes`, `store_fact` - Memory operations
- `mimo_store_memory`, `mimo_reload_skills` - Utility

### External Skills (37) - Extended Functionality
- **puppeteer_*** (7 tools) - Browser automation
- **desktop_commander_*** (23 tools) - Process/file management  
- **exa_search_*** (2 tools) - AI-powered web search
- **sequential_thinking** (1 tool) - Structured reasoning
- **fetch_*** (4 tools) - HTTP requests (redundant, remove in v3.1)

## The "Enhanced Brain" Value

**Without Mimo:**
```
Claude: "What's the status of Project X?"
AI: "I don't have access to that information." ← No memory
```

**With Mimo:**
```
Claude: "What's the status of Project X?"
Mimo: [searches episodic store]
→ Found: Retro notes, "Project X delayed 2 weeks, blocked on API"
→ Found: Last week, "API completed, Project X unblocked"
Mimo: "Project X was unblocked last week after API completion. Current status: in progress, delayed 2 weeks total."
```

**AI now has persistent, searchable, semantically-queryable memory.**

## v3.0 Roadmap: Perfect the Core

### Immediate (v2.4)
- ✅ Stdio routing fixed (DONE)
- ✅ Remove redundant fetch MCP server
- ✅ Memory leak prevention
- ✅ Hot reload polish

### Near-term (v3.0)
- **Semantic Store**: Graph DB integration (Neo4j)
  - Store millions of relationships
  - Time-aware queries (valid_from/until)
  - JSON-LD export
  
- **Procedural Store**: Rule engine
  - Forward/backward chaining
  - Context schema validation
  - Oban-based retry queue

- **Cross-Store Router**: Orchestration
  - Example: "Investigate failed deploy"
    1. Episodic: Search similar failures
    2. Semantic: Query service dependencies
    3. Procedural: Execute debugging playbook
    4. Store: "Added incident to knowledge graph"

### Long-term
- Distributed Mimo clusters
- Multi-agent memory sharing
- Memory import/export formats
- Vector quantization for scale

## Success Metrics

✅ **4000+ character context windows (Done)**  
✅ **O(1) memory streaming (Done)**  
✅ **Stdio MCP working (Done)**  
🎯 **v3.0: 1M+ entity graph (Next)**  
🎯 **v3.0: Procedural automation (Next)**  
🚀 **v4.0: Distributed memory mesh (Future)**

## Key Differentiator

**Every other MCP server is a tool. Mimo is a brain that remembers.**

The MCP interface makes this brain accessible to any AI, but the memory system is the actual innovation.
