defmodule Mimo.Telemetry.Metrics do
  @moduledoc """
  Prometheus-compatible metrics definitions for Mimo (SPEC-061).

  Exports metrics in a format compatible with:
  - Prometheus scraping
  - Grafana dashboards
  - AlertManager rules

  ## Production Targets (SPEC-061)

  | Metric | Target |
  |--------|--------|
  | p95 Search Latency | <1500ms |
  | p99 Search Latency | <3000ms |
  | Throughput | >100 req/s |
  | Error Rate | <1% |
  """

  @doc """
  Returns all metric definitions for the Mimo system.
  Compatible with `telemetry_metrics` library.
  """
  def metrics do
    [
      # =======================================================================
      # Production Performance Metrics (SPEC-061)
      # =======================================================================

      # Memory search latency - PRIMARY METRIC
      distribution("mimo.memory.search.duration",
        description: "Memory search latency (SPEC-061 target: p95 <1500ms)",
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [10, 50, 100, 250, 500, 1000, 1500, 2500, 5000]
        ]
      ),

      # Memory store latency
      distribution("mimo.memory.store.duration",
        description: "Memory store latency",
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [50, 100, 250, 500, 1000, 2000, 5000]
        ]
      ),

      # Tool dispatch latency
      distribution("mimo.tool.dispatch.duration",
        description: "Tool dispatch latency",
        unit: {:native, :millisecond},
        tags: [:tool_name],
        reporter_options: [
          buckets: [10, 50, 100, 500, 1000, 2500, 5000]
        ]
      ),

      # Request throughput counters
      counter("mimo.memory.search.count",
        description: "Total memory search operations"
      ),

      counter("mimo.memory.store.count",
        description: "Total memory store operations"
      ),

      counter("mimo.tool.dispatch.count",
        description: "Total tool dispatch operations",
        tags: [:tool_name]
      ),

      counter("mimo.errors.count",
        description: "Total errors by type",
        tags: [:type, :component]
      ),

      # =======================================================================
      # System Metrics
      # =======================================================================

      # Memory usage
      last_value("mimo.system.memory.bytes",
        description: "Total BEAM memory usage in bytes",
        unit: :byte
      ),

      last_value("mimo.memory.total_count",
        description: "Total memories in store"
      ),

      last_value("mimo.hnsw.index_size",
        description: "HNSW index size (number of vectors)"
      ),

      last_value("mimo.embedding_cache.hit_rate",
        description: "Embedding cache hit rate percentage"
      ),

      last_value("mimo.embedding_cache.size",
        description: "Number of cached embeddings"
      ),

      # Scheduler utilization
      last_value("mimo.system.schedulers.utilization",
        description: "BEAM scheduler utilization ratio",
        unit: :ratio
      ),

      # VM metrics
      last_value("vm.memory.total",
        description: "Total VM memory",
        unit: :byte
      ),

      last_value("vm.total_run_queue_lengths.total",
        description: "Total run queue length"
      ),

      last_value("vm.system_counts.process_count",
        description: "Number of BEAM processes"
      ),

      # =======================================================================
      # Semantic Store Metrics
      # =======================================================================

      # Query latency
      distribution("mimo.semantic_store.query.duration",
        description: "Semantic store query latency",
        unit: {:native, :millisecond},
        tags: [:query_type],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000]
        ]
      ),

      # Triple ingestion
      counter("mimo.semantic_store.ingest.total",
        description: "Total triples ingested",
        tags: [:source, :method]
      ),

      distribution("mimo.semantic_store.ingest.duration",
        description: "Ingestion latency",
        unit: {:native, :millisecond},
        tags: [:method],
        reporter_options: [
          buckets: [100, 500, 1000, 2000, 5000]
        ]
      ),

      # Entity resolution
      counter("mimo.semantic_store.resolve.total",
        description: "Total entity resolutions",
        tags: [:method, :type]
      ),

      distribution("mimo.semantic_store.resolve.duration",
        description: "Entity resolution latency",
        unit: {:native, :millisecond},
        tags: [:method],
        reporter_options: [
          buckets: [5, 10, 25, 50, 100, 250]
        ]
      ),

      summary("mimo.semantic_store.resolve.confidence",
        description: "Entity resolution confidence scores",
        tags: [:method]
      ),

      # Inference
      counter("mimo.semantic_store.inference.total",
        description: "Total inference passes",
        tags: [:graph_id]
      ),

      counter("mimo.semantic_store.inference.triples_created",
        description: "Triples created by inference",
        tags: [:graph_id]
      ),

      distribution("mimo.semantic_store.inference.duration",
        description: "Inference pass latency",
        unit: {:native, :millisecond},
        tags: [:graph_id],
        reporter_options: [
          buckets: [100, 500, 1000, 5000, 10_000, 30_000]
        ]
      ),

      # =======================================================================
      # Brain/Classifier Metrics
      # =======================================================================

      counter("mimo.brain.classify.total",
        description: "Total classifications",
        tags: [:intent, :path]
      ),

      distribution("mimo.brain.classify.duration",
        description: "Classification latency",
        unit: {:native, :millisecond},
        tags: [:path],
        reporter_options: [
          buckets: [1, 5, 10, 20, 50, 100, 500]
        ]
      ),

      summary("mimo.brain.classify.confidence",
        description: "Classification confidence scores",
        tags: [:intent]
      ),

      # =======================================================================
      # HTTP/API Metrics
      # =======================================================================

      counter("mimo.http.request.total",
        description: "Total HTTP requests",
        tags: [:method, :path, :status]
      ),

      distribution("mimo.http.request.duration",
        description: "HTTP request latency",
        unit: {:native, :millisecond},
        tags: [:method, :path],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000, 2500]
        ]
      ),

      # =======================================================================
      # HNSW Index Metrics
      # =======================================================================

      distribution("mimo.hnsw.search.duration",
        description: "HNSW search latency",
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100]
        ]
      ),

      distribution("mimo.hnsw.insert.duration",
        description: "HNSW insert latency",
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100]
        ]
      ),

      # =======================================================================
      # Embedding Cache Metrics
      # =======================================================================

      counter("mimo.embedding_cache.hits",
        description: "Embedding cache hits"
      ),

      counter("mimo.embedding_cache.misses",
        description: "Embedding cache misses"
      ),

      distribution("mimo.embedding.generate.duration",
        description: "Embedding generation latency (Ollama)",
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [50, 100, 200, 500, 1000, 2000]
        ]
      ),

      # =======================================================================
      # Error Handling Metrics
      # =======================================================================

      counter("mimo.error.total",
        description: "Total errors",
        tags: [:component, :error_type]
      ),

      counter("mimo.retry.total",
        description: "Total retry attempts",
        tags: [:component, :attempt]
      ),

      counter("mimo.circuit_breaker.state_change",
        description: "Circuit breaker state changes",
        tags: [:name, :from_state, :to_state]
      ),

      # =======================================================================
      # Observer Metrics
      # =======================================================================

      counter("mimo.observer.suggestions.total",
        description: "Total proactive suggestions made",
        tags: [:accepted]
      ),

      summary("mimo.observer.suggestions.confidence",
        description: "Suggestion confidence scores"
      )
    ]
  end

  # Helper functions for metric types
  defp counter(name, opts), do: {:counter, name, opts}
  defp distribution(name, opts), do: {:distribution, name, opts}
  defp summary(name, opts), do: {:summary, name, opts}
  defp last_value(name, opts), do: {:last_value, name, opts}

  @doc """
  Returns SLA definitions for alerting (SPEC-061).
  """
  def sla_thresholds do
    %{
      # SPEC-061 targets
      memory_search_p95_ms: 1500,
      memory_search_p99_ms: 3000,
      throughput_rps: 100,
      error_rate_percent: 1.0,

      # Existing SLAs
      entity_resolution_p95_ms: 50,
      classification_p95_ms: 20,
      graph_traversal_p95_ms: 100,
      triple_ingestion_p95_ms: 10,
      http_request_p95_ms: 500
    }
  end

  @doc """
  Returns alert rule definitions (SPEC-061).
  """
  def alert_rules do
    [
      # SPEC-061 Production Alerts
      %{
        name: "HighMemorySearchLatency",
        condition: "mimo_memory_search_duration_p95 > 1500",
        severity: :critical,
        description: "Memory search p95 latency exceeds 1500ms (SPEC-061 target)"
      },
      %{
        name: "HighMemorySearchP99Latency",
        condition: "mimo_memory_search_duration_p99 > 3000",
        severity: :warning,
        description: "Memory search p99 latency exceeds 3000ms"
      },
      %{
        name: "LowThroughput",
        condition: "rate(mimo_memory_search_count[5m]) < 100",
        severity: :warning,
        description: "Throughput below 100 req/s target"
      },

      # Existing alerts
      %{
        name: "HighEntityResolutionLatency",
        condition: "mimo_semantic_store_resolve_duration_p95 > 50",
        severity: :warning,
        description: "Entity resolution p95 latency exceeds 50ms"
      },
      %{
        name: "HighErrorRate",
        condition: "rate(mimo_error_total[5m]) > 0.01",
        severity: :critical,
        description: "Error rate exceeds 1%"
      },
      %{
        name: "CircuitBreakerOpen",
        condition: "mimo_circuit_breaker_state == 'open'",
        severity: :critical,
        description: "Circuit breaker is open"
      },
      %{
        name: "InferenceBacklog",
        condition: "mimo_semantic_store_inference_duration_p95 > 30000",
        severity: :warning,
        description: "Inference taking too long"
      },
      %{
        name: "HighMemoryUsage",
        condition: "mimo_system_memory_bytes > 1073741824",
        severity: :warning,
        description: "Memory usage exceeds 1GB"
      },
      %{
        name: "LowEmbeddingCacheHitRate",
        condition: "mimo_embedding_cache_hit_rate < 20",
        severity: :warning,
        description: "Embedding cache hit rate below 20%"
      }
    ]
  end
end
