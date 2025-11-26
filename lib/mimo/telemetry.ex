defmodule Mimo.Telemetry do
  @moduledoc """
  Telemetry supervisor for the Universal Aperture.

  Tracks metrics for:
  - HTTP request latency (p50, p95, p99)
  - Meta-Cognitive Router classification latency
  - Tool execution latency
  - Memory store query latency
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

    children = [
      # Telemetry poller for periodic metrics
      {:telemetry_poller,
       measurements: periodic_measurements(),
       period: :timer.seconds(10),
       name: :mimo_telemetry_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp attach_handlers do
    # HTTP request telemetry
    :telemetry.attach(
      "mimo-http-handler",
      [:mimo, :http, :request],
      &handle_http_event/4,
      nil
    )

    # Router classification telemetry
    :telemetry.attach(
      "mimo-router-handler",
      [:mimo, :router, :classify],
      &handle_router_event/4,
      nil
    )

    # Ask endpoint telemetry
    :telemetry.attach(
      "mimo-ask-handler",
      [:mimo, :http, :ask],
      &handle_ask_event/4,
      nil
    )

    # Tool endpoint telemetry
    :telemetry.attach(
      "mimo-tool-handler",
      [:mimo, :http, :tool],
      &handle_tool_event/4,
      nil
    )
  end

  defp handle_http_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    %{method: method, path: path, status: status} = metadata

    if latency_ms > 50 do
      Logger.warning(
        "[TELEMETRY] Slow HTTP: #{method} #{path} → #{status} (#{Float.round(latency_ms, 2)}ms)"
      )
    end
  end

  defp handle_router_event(_event, measurements, metadata, _config) do
    %{duration_us: duration_us, confidence: confidence} = measurements
    %{primary_store: primary_store} = metadata
    duration_ms = duration_us / 1000

    if duration_ms > 10 do
      Logger.warning(
        "[TELEMETRY] Slow router: #{primary_store} (#{Float.round(duration_ms, 2)}ms, confidence: #{confidence})"
      )
    end
  end

  defp handle_ask_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    context_id = Map.get(metadata, :context_id, "none")

    if latency_ms > 50 do
      Logger.warning(
        "[TELEMETRY] Slow ask: context=#{context_id} (#{Float.round(latency_ms, 2)}ms)"
      )
    end
  end

  defp handle_tool_event(_event, measurements, metadata, _config) do
    %{latency_ms: latency_ms} = measurements
    %{tool: tool} = metadata

    if latency_ms > 50 do
      Logger.warning("[TELEMETRY] Slow tool: #{tool} (#{Float.round(latency_ms, 2)}ms)")
    end
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_memory, []},
      {__MODULE__, :measure_schedulers, []}
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
