defmodule Mimo.Telemetry do
  @moduledoc """
  Telemetry supervisor for the Universal Aperture.

  Tracks metrics for:
  - HTTP request latency (p50, p95, p99)
  - Meta-Cognitive Router classification latency
  - Tool execution latency
  - Memory store query latency

  Exports metrics to Prometheus for alerting via:
  - `priv/prometheus/mimo_alerts.rules`
  - `priv/grafana/mimo-dashboard.json`
  """
  use Supervisor
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Attach telemetry handlers
    attach_handlers()

    # SPEC-061: Attach profiler handlers for performance monitoring
    if Application.get_env(:mimo_mcp, :profiling_enabled, false) do
      Mimo.Telemetry.Profiler.attach()
    end

    # Check if Prometheus should be disabled (for stdio MCP mode)
    prometheus_disabled = System.get_env("PROMETHEUS_DISABLED") == "true"

    children = [
      # Telemetry poller for periodic metrics
      {:telemetry_poller,
       measurements: periodic_measurements(),
       period: :timer.seconds(10),
       name: :mimo_telemetry_poller}
    ]

    # Only add Prometheus exporter if not disabled
    children =
      if prometheus_disabled do
        Logger.info("Prometheus metrics disabled (stdio mode)")
        children
      else
        children ++ [{TelemetryMetricsPrometheus, [metrics: prometheus_metrics()]}]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns Prometheus-compatible metric definitions.
  """
  def prometheus_metrics do
    import Telemetry.Metrics

    [
      # =======================================================================
      # System Metrics (for ResourceMonitor alerting)
      # =======================================================================
      last_value("mimo.resource_monitor.memory_mb",
        event_name: [:mimo, :system, :memory],
        measurement: :total_mb,
        description: "Total BEAM memory usage in MB"
      ),
      last_value("mimo.resource_monitor.process_count",
        event_name: [:mimo, :system, :processes],
        measurement: :count,
        description: "Number of BEAM processes"
      ),
      last_value("mimo.resource_monitor.port_count",
        event_name: [:mimo, :system, :ports],
        measurement: :count,
        description: "Number of open ports"
      ),

      # =======================================================================
      # HTTP Request Metrics
      # =======================================================================
      counter("mimo.http.request.total",
        event_name: [:mimo, :http, :request],
        tags: [:method, :path, :status],
        description: "Total HTTP requests"
      ),
      distribution("mimo.http.request.duration",
        event_name: [:mimo, :http, :request],
        measurement: :latency_ms,
        unit: {:native, :millisecond},
        tags: [:method, :path],
        description: "HTTP request latency distribution",
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500]]
      ),

      # =======================================================================
      # Semantic Store Metrics
      # =======================================================================
      distribution("mimo.semantic_store.query.duration",
        event_name: [:mimo, :semantic_store, :query],
        measurement: :duration_ms,
        unit: {:native, :millisecond},
        tags: [:query_type],
        description: "Semantic store query latency",
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000]]
      ),
      counter("mimo.semantic_store.ingest.total",
        event_name: [:mimo, :semantic_store, :ingest],
        tags: [:source],
        description: "Total triples ingested"
      ),

      # =======================================================================
      # Brain/Classifier Metrics
      # =======================================================================
      distribution("mimo.brain.classify.duration",
        event_name: [:mimo, :brain, :classify],
        measurement: :duration_ms,
        unit: {:native, :millisecond},
        tags: [:path],
        description: "Classification latency",
        reporter_options: [buckets: [1, 5, 10, 20, 50, 100, 500]]
      ),
      summary("mimo.brain.classify.confidence",
        event_name: [:mimo, :brain, :classify],
        measurement: :confidence,
        tags: [:intent],
        description: "Classification confidence scores"
      ),

      # =======================================================================
      # Router Metrics
      # =======================================================================
      distribution("mimo.router.classify.duration",
        event_name: [:mimo, :router, :classify],
        measurement: :duration_us,
        unit: {:native, :microsecond},
        tags: [:primary_store],
        description: "Router classification latency",
        reporter_options: [buckets: [100, 500, 1000, 5000, 10_000, 50_000]]
      ),
      summary("mimo.router.classify.confidence",
        event_name: [:mimo, :router, :classify],
        measurement: :confidence,
        tags: [:primary_store],
        description: "Router confidence scores"
      ),

      # =======================================================================
      # Error Metrics
      # =======================================================================
      counter("mimo.request.errors.total",
        event_name: [:mimo, :error],
        tags: [:component, :error_type],
        description: "Total errors by component"
      ),

      # =======================================================================
      # Classifier Cache Metrics
      # =======================================================================
      counter("mimo.cache.classifier.hit.count",
        event_name: [:mimo, :cache, :classifier, :hit],
        measurement: :count,
        tags: [:key_type],
        description: "Classifier cache hits"
      ),
      counter("mimo.cache.classifier.miss.count",
        event_name: [:mimo, :cache, :classifier, :miss],
        measurement: :count,
        tags: [:key_type],
        description: "Classifier cache misses"
      ),

      # =======================================================================
      # Health Check Metric
      # =======================================================================
      last_value("mimo.health_check.status",
        event_name: [:mimo, :health, :check],
        measurement: :status,
        description: "Health check status (1=healthy, 0=unhealthy)"
      )
    ]
  end

  defp attach_handlers do
    # HTTP request telemetry (using MFA to avoid local function warning)
    :telemetry.attach(
      "mimo-http-handler",
      [:mimo, :http, :request],
      &__MODULE__.handle_http_event/4,
      nil
    )

    # Router classification telemetry
    :telemetry.attach(
      "mimo-router-handler",
      [:mimo, :router, :classify],
      &__MODULE__.handle_router_event/4,
      nil
    )

    # Ask endpoint telemetry
    :telemetry.attach(
      "mimo-ask-handler",
      [:mimo, :http, :ask],
      &__MODULE__.handle_ask_event/4,
      nil
    )

    # Tool endpoint telemetry
    :telemetry.attach(
      "mimo-tool-handler",
      [:mimo, :http, :tool],
      &__MODULE__.handle_tool_event/4,
      nil
    )

    # Semantic Store telemetry
    :telemetry.attach(
      "mimo-semantic-query-handler",
      [:mimo, :semantic_store, :query],
      &__MODULE__.handle_semantic_query_event/4,
      nil
    )

    :telemetry.attach(
      "mimo-semantic-ingest-handler",
      [:mimo, :semantic_store, :ingest],
      &__MODULE__.handle_semantic_ingest_event/4,
      nil
    )

    :telemetry.attach(
      "mimo-entity-resolution-handler",
      [:mimo, :semantic_store, :resolve],
      &__MODULE__.handle_entity_resolution_event/4,
      nil
    )

    :telemetry.attach(
      "mimo-inference-handler",
      [:mimo, :semantic_store, :inference],
      &__MODULE__.handle_inference_event/4,
      nil
    )

    # Intent Classifier telemetry
    :telemetry.attach(
      "mimo-classifier-handler",
      [:mimo, :brain, :classify],
      &__MODULE__.handle_classifier_event/4,
      nil
    )
  end

  @doc false
  def handle_http_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    %{method: method, path: path, status: status} = metadata

    # Record latency for p99 calculation in LatencyGuard
    MimoWeb.Plugs.LatencyGuard.record_latency(latency_ms)

    if latency_ms > 50 do
      Logger.warning(
        "[TELEMETRY] Slow HTTP: #{method} #{path} → #{status} (#{Float.round(latency_ms, 2)}ms)"
      )
    end
  end

  @doc false
  def handle_router_event(_event, measurements, metadata, _config) do
    %{duration_us: duration_us, confidence: confidence} = measurements
    %{primary_store: primary_store} = metadata
    duration_ms = duration_us / 1000

    if duration_ms > 10 do
      Logger.warning(
        "[TELEMETRY] Slow router: #{primary_store} (#{Float.round(duration_ms, 2)}ms, confidence: #{confidence})"
      )
    end
  end

  @doc false
  def handle_ask_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    context_id = Map.get(metadata, :context_id, "none")

    if latency_ms > 50 do
      Logger.warning(
        "[TELEMETRY] Slow ask: context=#{context_id} (#{Float.round(latency_ms, 2)}ms)"
      )
    end
  end

  @doc false
  def handle_tool_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    %{tool: tool} = metadata

    if latency_ms > 50 do
      Logger.warning("[TELEMETRY] Slow tool: #{tool} (#{Float.round(latency_ms, 2)}ms)")
    end
  end

  @doc false
  def handle_semantic_query_event(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    query_type = Map.get(metadata, :query_type, "unknown")
    result_count = Map.get(metadata, :result_count, 0)

    if duration_ms > 100 do
      Logger.warning(
        "[TELEMETRY] Slow semantic query: #{query_type} returned #{result_count} results (#{Float.round(duration_ms / 1, 2)}ms)"
      )
    end
  end

  @doc false
  def handle_semantic_ingest_event(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    triple_count = Map.get(metadata, :triple_count, 0)
    source = Map.get(metadata, :source, "unknown")

    Logger.info(
      "[TELEMETRY] Ingested #{triple_count} triples from #{source} (#{Float.round(duration_ms / 1, 2)}ms)"
    )
  end

  @doc false
  def handle_entity_resolution_event(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    confidence = Map.get(metadata, :confidence, 0)
    method = Map.get(metadata, :method, "unknown")

    if duration_ms > 50 do
      Logger.warning(
        "[TELEMETRY] Slow entity resolution: #{method} (#{Float.round(duration_ms * 1.0, 2)}ms, confidence: #{confidence})"
      )
    end
  end

  @doc false
  def handle_inference_event(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    triples_created = Map.get(metadata, :triples_created, 0)
    graph_id = Map.get(metadata, :graph_id, "global")

    Logger.info(
      "[TELEMETRY] Inference pass on #{graph_id}: #{triples_created} new triples (#{Float.round(duration_ms * 1.0, 2)}ms)"
    )
  end

  @doc false
  def handle_classifier_event(_event, measurements, metadata, _config) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    intent = Map.get(metadata, :intent, "unknown")
    path = Map.get(metadata, :path, "unknown")
    confidence = Map.get(metadata, :confidence, 0)

    if duration_ms > 20 do
      Logger.warning(
        "[TELEMETRY] Slow classification: #{intent} via #{path} (#{Float.round(duration_ms * 1.0, 2)}ms, confidence: #{confidence})"
      )
    end
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_memory, []},
      {__MODULE__, :measure_schedulers, []},
      {MimoWeb.Plugs.RateLimiter, :cleanup_stale_entries, []}
    ]
  end

  @doc false
  def measure_memory do
    memory_mb = :erlang.memory(:total) / (1024 * 1024)

    :telemetry.execute(
      [:mimo, :system, :memory],
      %{bytes: :erlang.memory(:total), mb: memory_mb},
      %{}
    )
  end

  @doc false
  def measure_schedulers do
    schedulers = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:total_run_queue_lengths_all)
    utilization = run_queue / schedulers

    :telemetry.execute(
      [:mimo, :system, :schedulers],
      %{schedulers: schedulers, run_queue: run_queue, utilization: utilization},
      %{}
    )

    if utilization > 2.0 do
      Logger.warning("[TELEMETRY] High scheduler utilization: #{Float.round(utilization, 2)}")
    end
  end
end
