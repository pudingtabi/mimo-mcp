# Memory Retrieval Gaps Analysis

> **Date**: 2026-01-11
> **Goal**: Identify and fix gaps preventing Mimo from achieving "100% reliable recall"
> **Status**: ✅ ALL BUGS FIXED (2026-01-11)

---

## Executive Summary

~~Three critical bugs prevent reliable memory recall:~~ **All fixed!**

| Bug | Impact | Status |
|-----|--------|--------|
| List sort order inverted | Cannot browse recent memories | ✅ Fixed (line 1628) |
| Time filter fails for search | Cannot query by time | ✅ Fixed (line 1417) |
| Semantic search lacks recency | Recent work not prioritized | ✅ Fixed (temporal routing) |

### Verification (2026-01-12):
```bash
# Test 1: List recent - WORKS
memory operation=list sort=recent limit=5
# Returns: 2026-01-12 memories (most recent) ✅

# Test 2: Time filter - WORKS  
memory operation=search query="session work" time_filter="yesterday"
# Returns: 2026-01-11 memories ✅

# Test 3: Temporal query - WORKS
memory operation=search query="what was the work we did in the last session"
# query_type: "temporal", returns recent work ✅
```

---

## Bug 1: List Sort Order Inverted ✅ FIXED

**Status**: Fixed on 2026-01-11 in `lib/mimo/ports/tool_interface.ex` line 1628

```elixir
# Fixed code (line 1628):
# BUG FIX 2026-01-11: Was using [asc: e.id] which returned oldest first!
_ -> from(e in query, order_by: [desc: e.id])
```

---

## Bug 2: Time Filter Returns Zero Results ✅ FIXED

**Status**: Fixed on 2026-01-11 in `lib/mimo/ports/tool_interface.ex` lines 1417-1419

```elixir
# Fixed code:
nil ->
  # BUG FIX 2026-01-11: If no timestamp, exclude from time-filtered results
  # Previously returned true which caused all results to pass
  false
```

1. Change nil case to `false` - memories without timestamps shouldn't match time queries
2. Verify all search paths include `inserted_at`
3. Add debug logging for time filter application

---

## Bug 3: Semantic Search Doesn't Prioritize Recent Memories ✅ FIXED

**Status**: Fixed via temporal query routing in `lib/mimo/brain/memory_router.ex`

The temporal query detection now correctly identifies phrases like "last session" and routes to `recency_heavy` strategy (40% recency weight).

### Verification (2026-01-12):
```bash
memory operation=search query="what was the work we did in the last session"
# query_type: "temporal" ← Correctly detected!
# Returns: 2026-01-12 memories (most recent session)
```

### How It Works:
1. `MemoryRouter.analyze/1` detects temporal indicators ("last", "recent", "yesterday")
2. Routes to `temporal_route/2` which uses `:recency_heavy` strategy
3. `HybridRetriever` applies 40% weight to recency score
4. Recent memories bubble up even if semantic similarity is lower

---

## Human Memory Comparison (Updated 2026-01-12)

| Capability | Human | Mimo Target | Mimo Actual |
|------------|-------|-------------|-------------|
| "What did I work on yesterday?" | Natural recall | Should work | ✅ **WORKS** |
| "Find the auth discussion" | Keyword recall | Works | ✅ Works |
| Time-ordered browsing | Natural | List recent | ✅ **WORKS** |
| Importance weighting | Emotional salience | importance field | ⚠️ Partial |
| Forgetting curve | Natural decay | decay_rate | ⚠️ Exists but untested |

---

## Resolution Summary

All three bugs were fixed on 2026-01-11:

| Bug | Fix Location | Verification |
|-----|--------------|--------------|
| List sort order | `tool_interface.ex:1628` | `memory list sort=recent` returns newest first ✅ |
| Time filter nil | `tool_interface.ex:1417-1419` | `time_filter="yesterday"` filters correctly ✅ |
| Temporal routing | `memory_router.ex` | `query_type: "temporal"` detected ✅ |

---

## Testing Plan (Completed ✅)

All tests verified on 2026-01-12:

```bash
# Test 1: List recent - PASS ✅
memory operation=list sort=recent limit=5
# Returns: 2026-01-12 memories (most recent)

# Test 2: Time filter - PASS ✅
memory operation=search query="session work" time_filter="yesterday"
# Returns: 2026-01-11 memories

# Test 3: Natural temporal query - PASS ✅
memory operation=search query="what was the work we did in the last session"
# query_type: "temporal", returns recent work
```

---

## Future Improvements

| Improvement | Priority | Effort |
|-------------|----------|--------|
| Regression tests for time-based queries | Medium | 1 hour |
| Telemetry for query routing decisions | Low | 30 min |
| Test forgetting curve (decay_rate) | Low | 2 hours |

---

## References

- [SPEC-092: Query Intent Classification](../SPEC-092-query-intent-classification.md)
- [Memory Scalability Master Plan](../specs/MEMORY_SCALABILITY_MASTER_PLAN.md)
- [VISION.md](../../VISION.md) - "100% recall guaranteed" claim

---

*Originally Identified: 2026-01-11*  
*All Bugs Fixed: 2026-01-11*  
*Verification Completed: 2026-01-12*  
*Author: Skeptical analysis during session*

---

*Last Updated: 2026-01-11*
*Author: Skeptical analysis during session*
