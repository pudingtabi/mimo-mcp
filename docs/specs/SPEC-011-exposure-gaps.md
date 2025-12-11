# SPEC-011: Tool Exposure Gap Remediation

**Status**: Draft  
**Priority**: P0 (Critical)  
**Author**: Analysis from competitive review  
**Date**: 2025-11-29

## Problem Statement

Mimo has solid internal implementations that are **not exposed via MCP**:
- Procedural FSM exists but users can only `recall_procedure`, not `run_procedure`
- Memory operations are fragmented across multiple interfaces
- No file ingestion capability
- No memory browsing/listing

**Result**: Competitors with simpler internals appear more capable because their features are accessible.

---

## SPEC-011.1: Procedural Store MCP Exposure

### Current State
- `ExecutionFSM` - Full gen_statem implementation ✅
- `Loader` - Procedure loading ✅
- `recall_procedure` tool - Returns procedure definition ✅
- **`run_procedure` tool - MISSING** ❌

### Requirements

#### 010.1.1: `run_procedure` Tool

```
Tool: run_procedure
Description: Execute a registered procedure as a state machine

Input:
  - name: string (required) - Procedure name
  - version: string (optional, default: "latest")
  - context: object (optional) - Initial execution context
  - async: boolean (optional, default: false) - Return immediately with execution_id

Output (sync):
  - execution_id: string
  - status: "completed" | "failed" | "interrupted"
  - final_state: string
  - context: object - Final context after execution
  - history: array - State transitions
  - duration_ms: integer

Output (async):
  - execution_id: string
  - status: "running"
  - pid: string (internal reference)
```

#### 010.1.2: `procedure_status` Tool

```
Tool: procedure_status
Description: Check status of async procedure execution

Input:
  - execution_id: string (required)

Output:
  - execution_id: string
  - status: "running" | "completed" | "failed" | "interrupted"
  - current_state: string
  - context: object
  - elapsed_ms: integer
```

#### 010.1.3: `list_procedures` Tool

```
Tool: list_procedures
Description: List all registered procedures

Input:
  - (none)

Output:
  - procedures: array of:
    - name: string
    - version: string
    - description: string
    - state_count: integer
```

### Implementation Location
- `lib/mimo/ports/tool_interface.ex` - Add execute clauses
- `lib/mimo/tool_registry.ex` - Register new tools

### Acceptance Criteria
- [ ] Can run procedure via MCP and get final result
- [ ] Can run procedure async and poll status
- [ ] Can list all available procedures
- [ ] Telemetry events emitted for procedure execution

---

## SPEC-011.2: Unified Memory Tool

### Current State
- `store_fact` - In tool_interface.ex
- `search_vibes` - In tool_interface.ex  
- `ask_mimo` - In tool_interface.ex
- `knowledge` - In tools.ex (separate dispatcher)
- **No list/browse capability** ❌
- **No delete capability** ❌
- **No stats capability** ❌

### Requirements

#### 010.2.1: Consolidate into `memory` Tool

```
Tool: memory
Description: Unified memory operations

Input:
  operation: enum (required)
    - "store" - Store a fact/observation
    - "search" - Semantic search
    - "list" - Browse stored memories
    - "delete" - Remove a memory
    - "stats" - Get memory statistics
    - "decay_check" - Check decay status of memories

  # For store:
  content: string (required)
  category: enum ["fact", "observation", "action", "plan"]
  importance: float (0-1, default: 0.5)
  tags: array of strings (optional)

  # For search:
  query: string (required)
  limit: integer (default: 10)
  threshold: float (default: 0.3)
  category: string (optional filter)

  # For list:
  limit: integer (default: 20)
  offset: integer (default: 0)
  category: string (optional filter)
  sort: enum ["recent", "importance", "decay_score"] (default: "recent")

  # For delete:
  id: string (required)

  # For decay_check:
  threshold: float (default: 0.1)
  limit: integer (default: 50)
```

#### 010.2.2: Output Formats

**store response:**
```json
{
  "stored": true,
  "id": "uuid",
  "embedding_generated": true
}
```

**search response:**
```json
{
  "results": [
    {
      "id": "uuid",
      "content": "...",
      "category": "fact",
      "score": 0.87,
      "created_at": "ISO8601",
      "importance": 0.7
    }
  ],
  "total_searched": 1523
}
```

**list response:**
```json
{
  "memories": [...],
  "total": 1523,
  "offset": 0,
  "limit": 20
}
```

**stats response:**
```json
{
  "total_memories": 1523,
  "by_category": {
    "fact": 890,
    "observation": 412,
    "action": 156,
    "plan": 65
  },
  "avg_importance": 0.54,
  "avg_decay_score": 0.67,
  "at_risk_count": 23,
  "oldest": "ISO8601",
  "newest": "ISO8601"
}
```

**decay_check response:**
```json
{
  "at_risk": [
    {
      "id": "uuid",
      "content": "...",
      "decay_score": 0.08,
      "days_until_forgotten": 2.3
    }
  ],
  "threshold": 0.1,
  "total_checked": 1523
}
```

### Migration Path
1. Add `memory` tool with all operations
2. Keep `store_fact`, `search_vibes`, `ask_mimo` as aliases (deprecated)
3. Remove aliases in v3.0

### Acceptance Criteria
- [ ] Single `memory` tool handles all operations
- [ ] Can list memories with pagination
- [ ] Can see decay scores and at-risk memories
- [ ] Can delete memories
- [ ] Old tool names still work (with deprecation warning in logs)

---

## SPEC-011.3: File Ingestion

### Current State
- No file ingestion capability
- Users must manually call `store_fact` per item

### Requirements

#### 010.3.1: `ingest` Tool

```
Tool: ingest
Description: Ingest file content into memory with automatic chunking

Input:
  path: string (required) - File path
  strategy: enum (default: "auto")
    - "auto" - Detect based on file type
    - "paragraphs" - Split on double newlines
    - "lines" - One memory per N lines
    - "sentences" - Split on sentence boundaries
    - "markdown" - Respect markdown structure (headers as boundaries)
    - "whole" - Store entire file as one memory
  
  chunk_size: integer (optional) - Target chunk size in chars
  overlap: integer (optional) - Overlap between chunks
  category: enum (default: "fact")
  importance: float (default: 0.5)
  tags: array (optional) - Tags to apply to all chunks
  metadata: object (optional) - Additional metadata

Output:
  ingested: true
  chunks_created: integer
  file_size: integer
  strategy_used: string
  ids: array of chunk IDs
```

#### 010.3.2: Supported File Types

| Extension | Default Strategy | Notes |
|-----------|-----------------|-------|
| `.md` | markdown | Headers become chunk boundaries |
| `.txt` | paragraphs | Double newline splits |
| `.json` | whole | Store as-is |
| `.yaml` | whole | Store as-is |
| `.ex`, `.exs` | paragraphs | Function boundaries (future) |
| `.py` | paragraphs | Function boundaries (future) |

#### 010.3.3: Chunking Algorithm

```
1. Read file content
2. Apply strategy to split into chunks
3. For each chunk:
   a. Skip if empty or too small (< 10 chars)
   b. Generate embedding via LLM
   c. Store with metadata:
      - source_file: path
      - chunk_index: N
      - total_chunks: M
      - strategy: used
4. Return summary
```

### Constraints
- Max file size: 10MB (configurable)
- Max chunks per file: 1000 (configurable)
- Sandbox: Must respect SANDBOX_DIR if set

### Acceptance Criteria
- [ ] Can ingest .md file with markdown-aware chunking
- [ ] Can ingest .txt file with paragraph splitting
- [ ] Chunks have proper metadata linking to source
- [ ] Respects sandbox restrictions
- [ ] Reports ingestion statistics

---

## SPEC-011.4: Natural Time Queries

### Current State
- Search only accepts raw query strings
- No time-based filtering

### Requirements

#### 010.4.1: Time Expression Parser

Support natural language time expressions in search:

```
"yesterday" → last 24 hours
"today" → since midnight UTC
"last week" → last 7 days
"last month" → last 30 days
"this week" → since Monday
"2 days ago" → 48 hours ago to now
"between monday and wednesday" → date range
```

#### 010.4.2: Integration Points

Add `time_filter` parameter to memory search:

```
Tool: memory (search operation)
Additional Input:
  time_filter: string (optional) - Natural language time expression
  
  # Or explicit:
  from_date: ISO8601 (optional)
  to_date: ISO8601 (optional)
```

### Implementation
- Add `Mimo.Utils.TimeParser` module
- Integrate with `memory` search operation
- Add to SQL query as date range filter

### Acceptance Criteria
- [ ] "yesterday" returns memories from last 24h
- [ ] "last week" returns memories from last 7 days
- [ ] Can combine with semantic search
- [ ] Invalid expressions return helpful error

---

## Implementation Priority

| Spec | Priority | Effort | Value | Order |
|------|----------|--------|-------|-------|
| 011.1 Procedural Exposure | P0 | Medium | High | 1 |
| 011.2 Unified Memory | P0 | Medium | High | 2 |
| 011.3 File Ingestion | P1 | Medium | High | 3 |
| 011.4 Time Queries | P2 | Low | Medium | 4 |

---

## Non-Goals (Keep Simple)

- ❌ OAuth/authentication (single user)
- ❌ Cloud sync (local-first)
- ❌ Web dashboard (CLI/MCP sufficient)
- ❌ Multi-tenant (single user)
- ❌ PDF/DOCX parsing (text files only for now)
- ❌ Code AST analysis (future v3.0)

---

## Success Metrics

After implementation:
1. Users can run procedures via MCP
2. Users can browse their memories
3. Users can ingest files without manual chunking
4. All Mimo capabilities are MCP-accessible

**Goal**: Feature parity exposure - everything internal is external.
