# MIMO-MCP Production Readiness Tasks

You are completing 14 tasks to make mimo-mcp production-ready. All 329 tests pass. Execute in this exact order:

## PHASE 1: DEPENDENCIES (5 min)

### Task: Add Missing Dependencies
**File:** `mix.exs`
**Add to deps:**
```elixir
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
{:excoveralls, "~> 0.18", only: :test},
{:telemetry_metrics_prometheus, "~> 1.1"}
```
**Add to project:**
```elixir
test_coverage: [tool: ExCoveralls],
preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.html": :test]
```
**Run:** `mix deps.get`

---

## PHASE 2: CRITICAL TASKS (2-3 hours)

### Task 1: Database Migration
**Run:** `mix ecto.migrate`
**Validate:** 
```sql
EXPLAIN ANALYZE SELECT * FROM semantic_triples WHERE subject = 'test';
EXPLAIN ANALYZE SELECT * FROM engrams WHERE namespace = 'test';
```
**Success:** Query plans show index scans, execution <100ms

### Task 2: Dialyzer Static Analysis  
**Run:** `mix dialyzer` (first run: 30-60 min for PLT)
**Success:** Zero new warnings
**If warnings:** Fix type specs in flagged modules

### Task 3: Code Coverage
**Run:** `mix coveralls.html`
**Target:** >55% overall, >80% for `lib/mimo/mcp/`, `lib/mimo/semantic_store/`
**Output:** `cover/excoveralls.html`

### Task 4: Performance Benchmarks
**Run:** `mix run bench/runner.exs`
**Benchmarks:** memory_search, vector_math, semantic_query, port_spawn, mcp_protocol
**Output:** `bench/results/`
**Document results in:** `docs/PERFORMANCE_PROFILING_REPORT.md`

---

## PHASE 3: HIGH PRIORITY (4-6 hours)

### Task 5: Validate Index Performance
After migration, run real queries and document:
- Query latency before/after indexes
- EXPLAIN ANALYZE output for each index
- Update `docs/PERFORMANCE_PROFILING_REPORT.md`

### Task 6: Configure ResourceMonitor Alerting
**Config exists in:** `config/prod.exs` (`:alerting` key)
**Create:** `priv/prometheus/mimo_alerts.rules` with rules for:
- Memory > 800MB warning, > 1000MB critical
- Process count > 400 warning, > 500 critical  
- Port count > 80 warning, > 100 critical
**Wire telemetry events to Prometheus using telemetry_metrics_prometheus**

### Task 7: Deploy Monitoring Infrastructure
**Dashboard:** `priv/grafana/mimo-dashboard.json` (10 panels ready)
**Steps:**
1. Configure Prometheus datasource in Grafana
2. Import dashboard JSON
3. Verify all 10 panels show data
4. Configure alert routing (email/Slack/PagerDuty)

---

## PHASE 4: MEDIUM PRIORITY (6-8 hours)

### Task 8: Test Graceful Degradation
**Module:** `lib/mimo/fallback/graceful_degradation.ex`
**Test scenarios:**
```elixir
# Simulate LLM down - verify cached responses
Mimo.Fallback.GracefulDegradation.with_llm_fallback(fn -> raise "LLM down" end, cache_key: "test")

# Simulate DB down - verify in-memory fallback  
Mimo.Fallback.GracefulDegradation.with_db_fallback(fn -> raise "DB down" end)

# Simulate Ollama down - verify hash embeddings
Mimo.Fallback.GracefulDegradation.with_embedding_fallback(fn -> raise "Ollama down" end)
```

### Task 9: Test CircuitBreaker/RetryStrategies Under Load
**Modules:** `lib/mimo/circuit_breaker.ex`, `lib/mimo/error_handling/retry_strategies.ex`
**Test scenarios:**
1. Trigger 5 failures → verify circuit opens
2. Wait reset_timeout → verify half-open state
3. Success in half-open → verify circuit closes
4. 10% failure rate load test → verify stability

### Task 10: Complete Performance Profiling Report
**File:** `docs/PERFORMANCE_PROFILING_REPORT.md`
**Add actual data from:**
- Benchmark results (Phase 2, Task 4)
- Index performance (Phase 3, Task 5)
- Memory profiling with `:observer.start()`
- Hot path analysis with `:fprof`

---

## PHASE 5: LOW PRIORITY (6-8 hours)

### Task 11: Integrate Classifier Cache
**Module:** `lib/mimo/cache/classifier.ex`
**API:** `get_or_compute_embedding/2`, `get_or_compute_classification/2`
**Find call sites:** Search for LLM embedding/classification calls
**Wire in:** Replace direct LLM calls with cache-wrapped versions
**Verify:** `Mimo.Cache.Classifier.stats()` shows hit rate

### Task 12: Documentation Review
**Files to review:**
- `README.md` - installation, usage accurate?
- `docs/adrs/` - decisions documented?
- Inline `@doc` and `@moduledoc` - complete?
**Update any outdated information**

### Task 13: Vector DB Research (Research Only)
**Evaluate:** FAISS, Pinecone, Weaviate, Milvus
**Document in:** `docs/specs/vector_db_evaluation.md`
**Criteria:** latency, scalability, cost, Elixir integration

### Task 14: Full Pipeline Integration Test
**File:** `test/integration/full_pipeline_test.exs` (403 lines)
**Run:** `mix test test/integration/full_pipeline_test.exs`
**Verify:** All 14 test scenarios pass end-to-end

---

## SUCCESS CRITERIA

| Task | Verification |
|------|-------------|
| Migration | `EXPLAIN ANALYZE` shows index usage |
| Dialyzer | Zero new warnings |
| Coverage | >55% overall in HTML report |
| Benchmarks | Results saved to `bench/results/` |
| Index perf | Queries <100ms |
| Alerting | Alert fires on threshold breach |
| Monitoring | Grafana shows live metrics |
| Degradation | Fallbacks return valid responses |
| CircuitBreaker | State transitions work correctly |
| Profiling | Report has real data |
| Cache | Hit rate visible in stats |
| Docs | README accurate |
| Vector DB | Evaluation doc created |
| Integration | All tests pass |

## EXISTING ASSETS (DO NOT RECREATE)
- Migration file exists: `priv/repo/migrations/20251127080000_add_semantic_indexes_v3.exs`
- Benchmark suite exists: `bench/benchmark.exs`, `bench/runner.exs`
- Grafana dashboard exists: `priv/grafana/mimo-dashboard.json`
- CircuitBreaker exists: `lib/mimo/circuit_breaker.ex`
- RetryStrategies exists: `lib/mimo/error_handling/retry_strategies.ex`
- GracefulDegradation exists: `lib/mimo/fallback/graceful_degradation.ex`
- ClassifierCache exists: `lib/mimo/cache/classifier.ex`
- Integration tests exist: `test/integration/full_pipeline_test.exs`
- Telemetry exists: `lib/mimo/telemetry.ex`
- ResourceMonitor exists: `lib/mimo/resource_monitor.ex`
- Config exists: `config/prod.exs` (alerting thresholds configured)
