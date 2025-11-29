# Mimo MCP Memory System Enhancement - Master Implementation Plan

## 📋 Executive Summary

This document outlines the complete implementation plan for enhancing Mimo MCP's memory system based on the foundation research document. The plan covers 5 major specifications that address critical gaps in the current implementation.

### Current State Analysis

| Feature | Status | Gap |
|---------|--------|-----|
| Basic Memory Storage | ✅ Implemented | - |
| Vector Search | ✅ Implemented | Basic only |
| Semantic Graph | ✅ Implemented | - |
| Procedural Store | ✅ Implemented | - |
| Working Memory Buffer | ❌ Missing | **CRITICAL** |
| Memory Consolidation | ❌ Missing | **CRITICAL** |
| Forgetting/Decay | ❌ Missing | **HIGH** |
| Hybrid Retrieval | ❌ Missing | **MEDIUM** |
| Unified Router | ❌ Missing | **MEDIUM** |

---

## 🎯 Implementation Roadmap

### Phase 1: Foundation (Week 1)
**Focus:** Working Memory and Decay Fields

| Task | Spec | Days | Agent |
|------|------|------|-------|
| Working Memory Buffer | SPEC-001 | 2-3 | Any |
| Decay Database Fields | SPEC-003 (partial) | 0.5 | Any |

**Deliverables:**
- `Mimo.Brain.WorkingMemory` GenServer
- `Mimo.Brain.WorkingMemoryCleaner`
- Database migration for decay fields
- Unit tests

### Phase 2: Lifecycle Management (Week 2)
**Focus:** Consolidation and Forgetting

| Task | Spec | Days | Agent |
|------|------|------|-------|
| Memory Consolidation | SPEC-002 | 3-4 | Requires SPEC-001 |
| Forgetting System | SPEC-003 | 2 | Any |

**Deliverables:**
- `Mimo.Brain.Consolidator` GenServer
- `Mimo.Brain.DecayScorer` module
- `Mimo.Brain.Forgetting` GenServer
- Access tracking in Memory searches
- Unit and integration tests

### Phase 3: Intelligent Retrieval (Week 3)
**Focus:** Hybrid Search and Routing

| Task | Spec | Days | Agent |
|------|------|------|-------|
| Hybrid Retrieval | SPEC-004 | 2-3 | Requires SPEC-003 |
| Memory Router | SPEC-005 | 2 | Requires all |

**Deliverables:**
- `Mimo.Brain.HybridScorer` module
- `Mimo.Brain.HybridRetriever` module
- `Mimo.Brain.MemoryRouter` module
- Updated MCP tools
- Full test coverage

### Phase 4: Integration & Polish (Week 4)
**Focus:** End-to-end testing, documentation, performance

| Task | Days |
|------|------|
| Integration testing | 1-2 |
| Performance optimization | 1 |
| Documentation | 1 |
| Bug fixes | 1-2 |

---

## 📁 Specification Index

| Spec | Title | Priority | File |
|------|-------|----------|------|
| SPEC-001 | Working Memory Buffer | CRITICAL | [001-working-memory-buffer.md](./001-working-memory-buffer.md) |
| SPEC-002 | Memory Consolidation | CRITICAL | [002-memory-consolidation.md](./002-memory-consolidation.md) |
| SPEC-003 | Forgetting and Decay | HIGH | [003-forgetting-decay.md](./003-forgetting-decay.md) |
| SPEC-004 | Hybrid Retrieval | MEDIUM | [004-hybrid-retrieval.md](./004-hybrid-retrieval.md) |
| SPEC-005 | Unified Memory Router | MEDIUM | [005-memory-router.md](./005-memory-router.md) |

---

## 🤖 Agent Prompts Index

Optimized prompts for AI agents to execute each specification:

| Spec | Prompt File |
|------|-------------|
| SPEC-001 | [001-working-memory-agent-prompt.md](./prompts/001-working-memory-agent-prompt.md) |
| SPEC-002 | [002-consolidation-agent-prompt.md](./prompts/002-consolidation-agent-prompt.md) |
| SPEC-003 | [003-forgetting-agent-prompt.md](./prompts/003-forgetting-agent-prompt.md) |
| SPEC-004 | [004-hybrid-retrieval-agent-prompt.md](./prompts/004-hybrid-retrieval-agent-prompt.md) |
| SPEC-005 | [005-memory-router-agent-prompt.md](./prompts/005-memory-router-agent-prompt.md) |

---

## 🔗 Dependency Graph

```
                    ┌─────────────┐
                    │  SPEC-001   │
                    │  Working    │
                    │  Memory     │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         │
       ┌─────────────┐                  │
       │  SPEC-002   │                  │
       │Consolidation│                  │
       └─────────────┘                  │
                                        │
       ┌─────────────┐                  │
       │  SPEC-003   │◀─────────────────┘
       │ Forgetting  │      (access fields)
       └──────┬──────┘
              │
              ▼
       ┌─────────────┐
       │  SPEC-004   │
       │   Hybrid    │
       │  Retrieval  │
       └──────┬──────┘
              │
              ▼
       ┌─────────────┐
       │  SPEC-005   │
       │   Memory    │
       │   Router    │
       └─────────────┘
```

**Parallel Execution Possible:**
- SPEC-001 and SPEC-003 (database fields) can start simultaneously
- SPEC-002 must wait for SPEC-001
- SPEC-004 can start once SPEC-003 adds access fields
- SPEC-005 should be last (integrates all)

---

## 📂 Files to Create

### New Modules

```
lib/mimo/brain/
├── working_memory.ex          # SPEC-001
├── working_memory_item.ex     # SPEC-001
├── working_memory_cleaner.ex  # SPEC-001
├── consolidator.ex            # SPEC-002
├── decay_scorer.ex            # SPEC-003
├── forgetting.ex              # SPEC-003
├── hybrid_scorer.ex           # SPEC-004
├── hybrid_retriever.ex        # SPEC-004
└── memory_router.ex           # SPEC-005
```

### New Migrations

```
priv/repo/migrations/
└── YYYYMMDDHHMMSS_add_decay_fields.exs  # SPEC-003
```

### New Tests

```
test/mimo/brain/
├── working_memory_test.exs      # SPEC-001
├── consolidator_test.exs        # SPEC-002
├── decay_scorer_test.exs        # SPEC-003
├── forgetting_test.exs          # SPEC-003
├── hybrid_scorer_test.exs       # SPEC-004
├── hybrid_retriever_test.exs    # SPEC-004
└── memory_router_test.exs       # SPEC-005
```

---

## 📝 Files to Modify

| File | Specs | Changes |
|------|-------|---------|
| `lib/mimo/application.ex` | 001, 002, 003 | Add to supervision tree |
| `lib/mimo/brain/engram.ex` | 003 | Add decay fields |
| `lib/mimo/brain/memory.ex` | 003, 004 | Access tracking, hybrid_search |
| `lib/mimo/auto_memory.ex` | 001 | Store to working memory |
| `lib/mimo/tool_registry.ex` | 002, 004, 005 | Add/update tools |
| `lib/mimo/ports/tool_interface.ex` | 002, 004, 005 | Tool handlers |
| `lib/mimo/telemetry/metrics.ex` | ALL | Add metrics |
| `config/config.exs` | ALL | Add configuration |

---

## ⚙️ Configuration Summary

```elixir
# config/config.exs

# SPEC-001: Working Memory
config :mimo_mcp, :working_memory,
  enabled: true,
  ttl_seconds: 600,           # 10 minutes
  max_items: 100,
  cleanup_interval_ms: 30_000

# SPEC-002: Consolidation
config :mimo_mcp, :consolidation,
  enabled: true,
  interval_ms: 300_000,       # 5 minutes
  min_importance: 0.4,
  link_threshold: 0.7,
  extract_triples: true

# SPEC-003: Forgetting
config :mimo_mcp, :forgetting,
  enabled: true,
  interval_ms: 3_600_000,     # 1 hour
  threshold: 0.1,
  batch_size: 1000,
  dry_run: false
```

---

## 📊 Telemetry Events Summary

### SPEC-001: Working Memory
- `[:mimo, :working_memory, :stored]`
- `[:mimo, :working_memory, :retrieved]`
- `[:mimo, :working_memory, :expired]`
- `[:mimo, :working_memory, :evicted]`
- `[:mimo, :working_memory, :cleanup]`

### SPEC-002: Consolidation
- `[:mimo, :consolidation, :started]`
- `[:mimo, :consolidation, :completed]`
- `[:mimo, :consolidation, :failed]`

### SPEC-003: Forgetting
- `[:mimo, :memory, :forgetting, :started]`
- `[:mimo, :memory, :forgetting, :completed]`
- `[:mimo, :memory, :decayed]`
- `[:mimo, :memory, :accessed]`

### SPEC-004: Hybrid Retrieval
- `[:mimo, :memory, :hybrid_search]`

### SPEC-005: Memory Router
- `[:mimo, :memory_router, :query]`

---

## 🧪 Testing Strategy

### Unit Tests
Each module has dedicated test file with:
- Happy path tests
- Edge case tests
- Error handling tests
- Configuration tests

### Integration Tests
```
test/integration/
├── memory_lifecycle_test.exs  # Working → Consolidation → Long-term
├── decay_flow_test.exs        # Create → Access → Decay → Forget
└── retrieval_test.exs         # Router → Stores → Merge → Results
```

### Performance Tests
```
bench/
├── working_memory_bench.exs
├── consolidation_bench.exs
└── retrieval_bench.exs
```

---

## 🚀 Execution Guide

### For Single Agent (Sequential)

```bash
# Week 1
# Execute SPEC-001 prompt, verify, commit
# Execute SPEC-003 migration only

# Week 2  
# Execute SPEC-002 prompt (depends on SPEC-001)
# Execute SPEC-003 prompt (rest of it)

# Week 3
# Execute SPEC-004 prompt (depends on SPEC-003 access fields)
# Execute SPEC-005 prompt (depends on all)

# Week 4
# Integration testing
# Performance tuning
# Documentation
```

### For Multiple Agents (Parallel)

```bash
# Day 1-2: Agent A → SPEC-001, Agent B → SPEC-003 (migration + schema)
# Day 3-4: Agent A → SPEC-002, Agent B → SPEC-003 (complete)
# Day 5-6: Agent A → SPEC-004, Agent B → SPEC-005 (once 004 complete)
# Day 7+: Integration, testing, polish
```

---

## ✅ Success Criteria

### Per-Spec Criteria
See individual spec documents for detailed acceptance criteria.

### Overall System Criteria

| Metric | Target |
|--------|--------|
| All specs implemented | 100% |
| Test coverage | > 80% |
| No regression in existing tests | 100% |
| Consolidation runs successfully | Every 5 min |
| Forgetting runs successfully | Every 1 hour |
| Query latency overhead | < 15% |
| Memory efficiency | < 100MB for 10K memories |

---

## 📚 References

- [Foundation Research Document](../references/research%20abt%20memory%20mcp.pdf)
- [Existing Memory Implementation](../../lib/mimo/brain/memory.ex)
- [Semantic Store](../../lib/mimo/semantic_store/)
- [Procedural Store](../../lib/mimo/procedural_store/)

---

## 🆘 Troubleshooting

### Common Issues

**Migration fails:**
```bash
mix ecto.rollback
# Fix migration
mix ecto.migrate
```

**GenServer crashes on start:**
- Check supervision tree order
- Verify dependencies are started first
- Check config values

**Tests timeout:**
- Increase timeout for consolidation tests
- Use `async: false` for tests that need database isolation

**Memory leak suspected:**
- Check ETS table size: `:ets.info(:mimo_working_memory)`
- Check Engram count: `Mimo.Brain.Memory.count()`
- Review cleanup intervals

---

## 📞 Support

For questions or issues:
1. Check existing spec document
2. Review agent prompt for implementation details
3. Search codebase for similar patterns
4. Run tests to verify current state
