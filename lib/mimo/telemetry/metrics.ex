defmodule Mimo.Telemetry.Metrics do
  @moduledoc """
  Prometheus-compatible metrics definitions for Mimo.

  Exports metrics in a format compatible with:
  - Prometheus scraping
  - Grafana dashboards
  - AlertManager rules
  """

  @doc """
  Returns all metric definitions for the Mimo system.
  Compatible with `telemetry_metrics` library.
  """
  def metrics do
    [
      # =======================================================================
      # System Metrics
      # =======================================================================

      # Memory usage
      last_value("mimo.system.memory.bytes",
        description: "Total BEAM memory usage in bytes",
        unit: :byte
      ),

      # Scheduler utilization
      last_value("mimo.system.schedulers.utilization",
        description: "BEAM scheduler utilization ratio",
        unit: :ratio
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
          buckets: [100, 500, 1000, 5000, 10000, 30000]
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

      # Tool execution
      counter("mimo.tool.execution.total",
        description: "Total tool executions",
        tags: [:tool, :status]
      ),
      distribution("mimo.tool.execution.duration",
        description: "Tool execution latency",
        unit: {:native, :millisecond},
        tags: [:tool],
        reporter_options: [
          buckets: [10, 50, 100, 500, 1000, 5000, 30000]
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
  Returns SLA definitions for alerting.
  """
  def sla_thresholds do
    %{
      entity_resolution_p95_ms: 50,
      classification_p95_ms: 20,
      graph_traversal_p95_ms: 100,
      triple_ingestion_p95_ms: 10,
      http_request_p95_ms: 500,
      error_rate_percent: 2.0
    }
  end

  @doc """
  Returns alert rule definitions.
  """
  def alert_rules do
    [
      %{
        name: "HighEntityResolutionLatency",
        condition: "mimo_semantic_store_resolve_duration_p95 > 50",
        severity: :warning,
        description: "Entity resolution p95 latency exceeds 50ms"
      },
      %{
        name: "HighErrorRate",
        condition: "rate(mimo_error_total[5m]) > 0.02",
        severity: :critical,
        description: "Error rate exceeds 2%"
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
      }
    ]
  end
end
