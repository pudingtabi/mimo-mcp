# ADR 004: Error Handling Strategy

## Status
Accepted

## Context
Mimo depends on multiple external services:
- **OpenRouter** - LLM reasoning
- **Ollama** - Local embeddings
- **External MCP Skills** - Subprocess execution
- **SQLite** - Database operations

Each service can fail independently. Without proper error handling:
- Single service failure cascades to entire application
- Temporary failures cause permanent unavailability
- No visibility into failure patterns

## Decision
Implement a **multi-layer error handling strategy** with:
1. Circuit Breakers for external services
2. Retry Strategies for transient failures
3. Fallback Behavior for graceful degradation
4. Telemetry for observability

### Circuit Breaker Pattern

```elixir
# lib/mimo/error_handling/circuit_breaker.ex

# States:
# - :closed - Normal operation, requests flow through
# - :open - Failure threshold reached, requests fail fast
# - :half_open - Testing if service recovered

# Configuration (config/prod.exs):
config :mimo_mcp, :circuit_breaker,
  llm_service: [
    failure_threshold: 5,      # Open after 5 failures
    reset_timeout_ms: 60_000,  # Try again after 1 minute
    half_open_max_calls: 3     # Test with 3 calls before closing
  ]
```

### Retry Strategy

```elixir
# lib/mimo/error_handling/retry_strategies.ex

# Exponential backoff with jitter:
# Attempt 1: 1000ms
# Attempt 2: 2000ms + jitter
# Attempt 3: 4000ms + jitter
# Max: 30000ms

RetryStrategies.with_retry(
  fn -> Repo.insert(changeset) end,
  max_retries: 3,
  base_delay: 1000,
  on_retry: fn attempt, reason ->
    Logger.warning("Retry #{attempt}: #{inspect(reason)}")
  end
)
```

### Fallback Behavior

| Service | Primary | Fallback |
|---------|---------|----------|
| LLM Reasoning | OpenRouter API | Return cached/static response |
| Embeddings | Ollama API | Hash-based pseudo-embedding |
| Vector Math | Rust NIF | Pure Elixir implementation |
| Database | SQLite | Error response (no fallback) |

### Integration Points

```elixir
# LLM calls wrapped with circuit breaker
def complete(prompt, opts \\ []) do
  CircuitBreaker.call(:llm_service, fn ->
    do_complete(prompt, opts)
  end)
end

# Database operations with retry
def persist_memory(content, category, importance) do
  RetryStrategies.with_retry(
    fn -> do_persist_memory(content, category, importance) end,
    max_retries: 3,
    base_delay: 100
  )
end

# Embeddings with circuit breaker + fallback
def generate_embedding(text) do
  CircuitBreaker.call(:ollama, fn ->
    case do_generate_embedding(text) do
      {:ok, embedding} -> {:ok, embedding}
      {:error, _} -> {:ok, fallback_embedding(text)}
    end
  end)
end
```

## Consequences

### Positive
- Failures don't cascade
- Fast failure when services are down
- Automatic recovery when services return
- Observable failure patterns

### Negative
- Additional code complexity
- Latency overhead for healthy calls (~1-2ms)
- Configuration tuning required per service

### Risks
- Incorrect thresholds cause premature circuit opening
- Retry storms during partial outages
- Fallback responses may confuse users

## Monitoring

Circuit breaker state is exposed via ResourceMonitor:

```elixir
# Telemetry events emitted:
[:mimo, :circuit_breaker, :opened]
[:mimo, :circuit_breaker, :closed]
[:mimo, :circuit_breaker, :half_open]
[:mimo, :retry, :attempt]
[:mimo, :retry, :exhausted]
```

## Notes
- Circuit breakers registered in `Mimo.CircuitBreaker.Registry`
- Per-service configuration in `config/prod.exs`
- Retry strategies are synchronous (block caller)
