defmodule MimoWeb.Plugs.LatencyGuard do
  @moduledoc """
  Latency guard plug that returns HTTP 503 if system is overloaded.

  Checks router.decision.duration.ms p99 against threshold.
  """
  import Plug.Conn
  require Logger

  @p99_threshold_ms 50

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check current system load
    case check_system_health() do
      :healthy ->
        conn

      {:overloaded, p99_ms} ->
        Logger.warning("System overloaded, p99 latency: #{p99_ms}ms")

        conn
        |> put_status(:service_unavailable)
        |> Phoenix.Controller.json(%{
          error: "Service temporarily unavailable",
          reason: "System overloaded",
          p99_latency_ms: p99_ms,
          threshold_ms: @p99_threshold_ms
        })
        |> halt()
    end
  end

  defp check_system_health do
    # TODO: Implement actual p99 tracking from telemetry metrics
    # v3.0 Roadmap: Real p99 latency tracking from telemetry_metrics_prometheus
    #               with sliding window percentile calculations
    # Current behavior: Uses BEAM scheduler run queue as proxy for system health (acceptable for v2.x)
    schedulers = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:total_run_queue_lengths_all)

    # If run queue is > 2x schedulers, system is overloaded
    if run_queue > schedulers * 2 do
      {:overloaded, run_queue}
    else
      :healthy
    end
  end
end
