# Agent Prompt: SPEC-006 Semantic Store Production Validation

## Mission
Validate Semantic Store for production readiness through comprehensive testing, benchmarking, and hardening. Transform status from "⚠️ Beta" to "✅ Production Ready".

## Context
- **Workspace**: `/workspace/mrc-server/mimo-mcp`
- **Spec**: `docs/specs/006-semantic-store-validation.md`
- **Target Modules**: `lib/mimo/semantic_store/*.ex`
- **Test Location**: `test/mimo/semantic_store/`
- **Benchmark Location**: `bench/semantic_store/`

## Phase 1: Scale Testing (Create Benchmarks)

### Task 1.1: Create Scale Test Suite
Create `bench/semantic_store/scale_test.exs`:

```elixir
# Test with increasing data sizes
# Target: 10K, 50K, 100K triples
# Measure: insert time, query time, memory usage
```

**Acceptance Criteria:**
- [ ] Insert 10K triples < 30 seconds
- [ ] Insert 50K triples < 3 minutes
- [ ] Query time < 100ms for 10K dataset
- [ ] Query time < 500ms for 50K dataset
- [ ] Memory usage < 500MB for 50K triples

### Task 1.2: Create Multi-hop Query Benchmark
Create `bench/semantic_store/traversal_bench.exs`:

```elixir
# Test recursive CTE performance
# Depths: 1, 2, 3, 5, 10 hops
# Graph sizes: 1K, 10K, 50K nodes
```

**Acceptance Criteria:**
- [ ] 3-hop query < 200ms on 10K nodes
- [ ] 5-hop query < 1s on 10K nodes
- [ ] No exponential blowup with depth

## Phase 2: Edge Case Hardening

### Task 2.1: Circular Reference Handling
File: `lib/mimo/semantic_store/query.ex`

Test and fix:
```elixir
# A -> B -> C -> A (cycle)
# Query should NOT infinite loop
# Should return path without revisiting
```

Create test in `test/mimo/semantic_store/query_test.exs`:
- [ ] Test cycle detection
- [ ] Test max depth enforcement
- [ ] Test visited node tracking

### Task 2.2: Unicode and Special Characters
Create `test/mimo/semantic_store/unicode_test.exs`:

```elixir
# Test entities with:
# - Unicode: "用户", "пользователь", "🚀"
# - Special chars: "O'Brien", "path/to/file"
# - Long strings: 10KB entity names
# - Empty strings, nil handling
```

### Task 2.3: Concurrent Access Testing
Create `test/mimo/semantic_store/concurrent_test.exs`:

```elixir
# Spawn 100 concurrent readers/writers
# Test for:
# - No deadlocks
# - No data corruption
# - Proper transaction isolation
```

## Phase 3: Performance Optimization

### Task 3.1: Add Database Indexes
Create migration `priv/repo/migrations/YYYYMMDDHHMMSS_add_semantic_indexes.exs`:

```elixir
# Indexes needed:
# - triples(subject_id, predicate)
# - triples(object_id, predicate)
# - triples(predicate, graph_id)
# - entity_anchors(content, graph_id)
```

### Task 3.2: Query Result Caching
File: `lib/mimo/semantic_store/query_cache.ex`

Implement:
- [ ] ETS-based query cache
- [ ] TTL-based invalidation (5 min default)
- [ ] Cache key based on query + params hash
- [ ] Invalidation on write operations

### Task 3.3: Batch Insert Optimization
File: `lib/mimo/semantic_store/repository.ex`

Implement:
```elixir
def bulk_create(triples, opts \\ []) do
  # Use Repo.insert_all for batch inserts
  # Chunk into 1000-triple batches
  # Return count and timing metrics
end
```

## Phase 4: Observability

### Task 4.1: Add Comprehensive Telemetry
File: `lib/mimo/semantic_store/telemetry.ex`

Events to emit:
```elixir
[:mimo, :semantic_store, :query, :start]
[:mimo, :semantic_store, :query, :stop]
[:mimo, :semantic_store, :insert, :stop]
[:mimo, :semantic_store, :traversal, :stop]
[:mimo, :semantic_store, :cache, :hit]
[:mimo, :semantic_store, :cache, :miss]
```

### Task 4.2: Health Check Endpoint
Add to `lib/mimo/semantic_store.ex`:

```elixir
def health_check do
  %{
    status: :ok,
    triple_count: count_triples(),
    entity_count: count_entities(),
    last_query_ms: get_last_query_time(),
    cache_hit_rate: get_cache_stats()
  }
end
```

## Phase 5: Documentation & Validation Report

### Task 5.1: Generate Validation Report
After all tests pass, create `docs/verification/semantic-store-validation-report.md`:

```markdown
# Semantic Store Production Validation Report

## Test Results
- Unit Tests: X passed, 0 failed
- Scale Tests: [results]
- Concurrent Tests: [results]
- Edge Case Tests: [results]

## Performance Benchmarks
| Operation | 10K | 50K | 100K | Target |
|-----------|-----|-----|------|--------|
| Insert (s)| X   | X   | X    | <30s   |
| Query (ms)| X   | X   | X    | <500ms |

## Recommendation
[READY/NOT READY] for production with notes
```

## Execution Order

```
1. Phase 1 (Scale Testing) - Establish baselines
2. Phase 2 (Edge Cases) - Find bugs
3. Phase 3 (Optimization) - Fix performance issues
4. Phase 4 (Observability) - Add monitoring
5. Phase 5 (Documentation) - Generate report
```

## Success Criteria

All must be GREEN:
- [ ] 50K triple insert < 3 minutes
- [ ] Query < 500ms at 50K scale
- [ ] No crashes on edge cases
- [ ] Concurrent test passes (100 workers)
- [ ] All new tests pass
- [ ] Validation report generated

## Commands

```bash
# Run scale benchmarks
mix run bench/semantic_store/scale_test.exs

# Run traversal benchmarks
mix run bench/semantic_store/traversal_bench.exs

# Run all semantic store tests
mix test test/mimo/semantic_store/ --include integration

# Run concurrent test
mix test test/mimo/semantic_store/concurrent_test.exs

# Full validation
mix test && mix run bench/semantic_store/scale_test.exs
```

## Notes for Agent

1. **Create benchmarks FIRST** - we need baseline numbers
2. **Run each benchmark 3 times** - average the results
3. **If performance fails, optimize BEFORE edge case testing**
4. **Document ALL findings in validation report**
5. **Update README.md status only after ALL criteria pass**
