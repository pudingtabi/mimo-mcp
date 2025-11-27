# MIMO-MCP Production Validation Tasks

Complete 7 remaining tasks to achieve 100% production readiness. All core implementations are done; this phase is validation, testing, and deployment.

## PHASE 1: CRITICAL FIX (1 hour)

### Task 1: Fix 2 Integration Test Failures ⭐ HIGHEST PRIORITY
**File:** `test/integration/full_pipeline_test.exs`
**Status:** 43 tests, 2 failures (95% pass rate)

**Root Cause Analysis:**
The test checks `function_exported?(Mimo.ErrorHandling.CircuitBreaker, :call, 2)` - the API exists correctly in `lib/mimo/circuit_breaker.ex`. Likely cause: **Registry startup issue** - the module uses `Mimo.CircuitBreaker.Registry` which must be started.

**Debug Steps:**
```bash
# Run with verbose output
mix test test/integration/full_pipeline_test.exs --trace

# Check if Registry is in supervision tree
grep -r "Mimo.CircuitBreaker.Registry" lib/
```

**Fix approach:**
1. Ensure `Mimo.CircuitBreaker.Registry` is started in application supervision tree
2. Or add registry startup to test setup in `test/support/` fixtures
3. Verify module loads correctly with `Code.ensure_loaded(Mimo.ErrorHandling.CircuitBreaker)`

**Verify:** `mix test test/integration/full_pipeline_test.exs` → 0 failures

---

## PHASE 2: HIGH PRIORITY VALIDATION (8-10 hours)

### Task 2: Verify Exact Code Coverage
**Effort:** 5 minutes
```bash
# Quick check from generated report
grep -oE '[0-9.]+%' cover/excoveralls.html | tail -1

# Or regenerate
mix coveralls.html
```
**Goal:** Document accurate coverage percentage

---

### Task 3: Add Classifier Cache Telemetry
**File:** `lib/mimo/cache/classifier.ex`
**Status:** Has internal hit/miss counters, NO telemetry events emitted

**Add telemetry calls:**
```elixir
# On cache hit (around line 160)
:telemetry.execute([:mimo, :cache, :classifier, :hit], %{count: 1}, %{key_type: type})

# On cache miss (around line 165)  
:telemetry.execute([:mimo, :cache, :classifier, :miss], %{count: 1}, %{key_type: type})
```

**Add metric definitions in** `lib/mimo/telemetry.ex`:
```elixir
counter("mimo.cache.classifier.hit.count"),
counter("mimo.cache.classifier.miss.count")
```

**Verify:** Call `Mimo.Cache.Classifier.stats()` → shows hit_rate, confirm telemetry events fire

---

### Task 4: Test CircuitBreaker Under Real Load
**Module:** `lib/mimo/circuit_breaker.ex`
**API:** `call/2`, `get_state/1`, `reset/1`, `record_failure/1`, `record_success/1`

**Test scenarios to create** (file: `test/integration/circuit_breaker_load_test.exs`):

```elixir
describe "CircuitBreaker under real failures" do
  test "opens after 5 consecutive failures" do
    # Trigger 5 failures
    for _ <- 1..5 do
      CircuitBreaker.record_failure(:llm_service)
    end
    assert CircuitBreaker.get_state(:llm_service) == :open
  end

  test "half-open after reset_timeout (60s)" do
    # Use Process.send_after or time travel
    # Verify state transitions to :half_open
  end

  test "closes on success in half-open state" do
    # Set to half-open, record success
    # Verify returns to :closed
  end

  test "handles concurrent failures correctly" do
    # Spawn 100 tasks that all fail
    # Verify circuit opens, no race conditions
  end
end
```

**Verify:** All state transitions work under concurrent load

---

### Task 5: Test Graceful Degradation End-to-End
**Module:** `lib/mimo/fallback/graceful_degradation.ex`
**API:** `with_llm_fallback/2`, `with_semantic_fallback/2`, `with_db_fallback/2`, `with_embedding_fallback/1`

**Test scenarios** (file: `test/integration/graceful_degradation_test.exs`):

```elixir
describe "Graceful degradation under real failures" do
  test "LLM down → returns cached/default response" do
    # Force circuit open for :llm_service
    for _ <- 1..5, do: CircuitBreaker.record_failure(:llm_service)
    
    result = GracefulDegradation.with_llm_fallback(
      fn -> raise "LLM timeout" end,
      cache_key: "test_query"
    )
    assert {:ok, _fallback_response} = result
  end

  test "Ollama down → generates hash-based embeddings" do
    result = GracefulDegradation.with_embedding_fallback(
      fn -> raise "Ollama unavailable" end
    )
    # Should return deterministic hash-based vector
    assert {:ok, embedding} = result
    assert length(embedding) == 384  # or expected dimension
  end

  test "DB down → uses in-memory cache fallback" do
    result = GracefulDegradation.with_db_fallback(
      fn -> raise "DB connection lost" end
    )
    assert {:ok, _cached_data} = result
  end

  test "telemetry fires on fallback trigger" do
    # Attach telemetry handler, verify [:mimo, :fallback, :triggered] event
  end
end
```

**Verify:** All fallback paths return valid responses, telemetry events fire

---

## PHASE 3: MONITORING & LOAD TESTING (6-9 hours)

### Task 6: Deploy Prometheus & Grafana Stack
**Existing files:**
- `priv/prometheus/mimo_alerts.rules` ✅ (alert rules complete)
- `priv/grafana/mimo-dashboard.json` ✅ (dashboard complete)

**Missing files to create:**

**`priv/prometheus/prometheus.yml`:**
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/mimo_alerts.rules

scrape_configs:
  - job_name: 'mimo-mcp'
    static_configs:
      - targets: ['mimo:4000']
    metrics_path: '/metrics'
```

**`priv/prometheus/alertmanager.yml`:**
```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'
    # Configure Slack/PagerDuty/email as needed
```

**Deployment steps:**
1. Add prometheus/grafana to `docker-compose.yml` or deploy separately
2. Configure datasource in Grafana pointing to Prometheus
3. Import `mimo-dashboard.json`
4. Verify all panels show live data
5. Test alert firing (manually trigger threshold)

---

### Task 7: Run Production Load Tests
**Existing:** `bench/benchmark.exs` (Elixir-based, small datasets)
**Missing:** HTTP load testing with concurrent users

**Create `bench/load_test.exs`:**
```elixir
defmodule Mimo.LoadTest do
  @base_url "http://localhost:4000"
  
  def run(concurrent_users \\ 100, duration_seconds \\ 60) do
    # Spawn concurrent_users tasks
    # Each task makes continuous requests for duration_seconds
    # Track: latency, errors, throughput
  end
  
  def test_memory_search_load(n_memories \\ 10_000) do
    # Seed n_memories, then run concurrent searches
  end
  
  def test_with_failure_injection(failure_rate \\ 0.1) do
    # Run load while randomly failing 10% of backend calls
  end
end
```

**Or use k6** (`bench/load_test.js`):
```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 100,
  duration: '5m',
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function() {
  const res = http.post('http://localhost:4000/api/ask', 
    JSON.stringify({ query: 'test query' }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(0.1);
}
```

**Success criteria:**
- p95 latency < 500ms
- p99 latency < 1000ms  
- Error rate < 1%
- Memory stable (no growth over time)

---

### Task 8: Document Rollback Procedure
**Create:** `docs/ROLLBACK_PROCEDURE.md`

**Contents:**
```markdown
# Production Rollback Procedure

## Quick Rollback (< 5 minutes)
1. `docker-compose down mimo`
2. `docker tag mimo:current mimo:failed`
3. `docker tag mimo:previous mimo:current`
4. `docker-compose up -d mimo`

## Database Rollback
mix ecto.rollback --step 1

## Verification After Rollback
1. Health check: `curl http://localhost:4000/health`
2. Smoke test: Run critical API calls
3. Monitor error rates in Grafana

## Communication
- Notify: #engineering channel
- Update: Status page
- Document: Post-mortem if needed
```

---

## SUCCESS CRITERIA

| Task | Verification | Blocks Prod? |
|------|-------------|--------------|
| Integration tests | 0 failures in `mix test test/integration/` | YES |
| Coverage | Documented accurate % | NO |
| Cache telemetry | Events appear in metrics | NO |
| CircuitBreaker load | All state transitions work | YES |
| Graceful degradation | Fallbacks return valid data | YES |
| Monitoring | Grafana shows live metrics | NO |
| Load tests | p95 < 500ms, errors < 1% | YES |
| Rollback docs | Document exists and reviewed | NO |

## TIMELINE

| Phase | Tasks | Time |
|-------|-------|------|
| Critical | Fix 2 test failures | 1 hour |
| Validation | CircuitBreaker + Degradation tests | 5-7 hours |
| Deployment | Monitoring + Load tests + Docs | 6-9 hours |
| **Total** | | **12-17 hours** |

## ALREADY COMPLETE (DO NOT REDO)
- ✅ Elixir 1.15.7 installed
- ✅ Database migrations applied
- ✅ Dialyzer run (43 warnings, non-blocking)
- ✅ Benchmarks executed (5.59x speedup documented)
- ✅ Prometheus alert rules configured
- ✅ Grafana dashboard created
- ✅ Graceful degradation implemented
- ✅ CircuitBreaker state machine implemented
- ✅ Classifier cache integrated
- ✅ README updated
- ✅ Vector DB research complete (Qdrant recommended)
