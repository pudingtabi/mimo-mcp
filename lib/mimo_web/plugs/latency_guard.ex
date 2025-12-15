defmodule MimoWeb.Plugs.LatencyGuard do
  @moduledoc """
  Latency guard plug that returns HTTP 503 if system is overloaded.

  Uses ETS-based sliding window for real p99 latency tracking,
  with BEAM scheduler utilization as a secondary signal.
  """
  import Plug.Conn
  require Logger

  @p99_threshold_ms 50
  @latency_table :latency_guard_samples
  @window_size 100

  def init(opts) do
    # Initialize ETS table for latency samples if it doesn't exist
    if :ets.whereis(@latency_table) == :undefined do
      Mimo.EtsSafe.ensure_table(@latency_table, [
        :named_table,
        :ordered_set,
        :public,
        write_concurrency: true
      ])
    end

    opts
  end

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

  @doc """
  Records a latency sample for p99 calculation.
  Called from telemetry handlers to track request latencies.
  """
  @spec record_latency(number()) :: :ok
  def record_latency(latency_ms) when is_number(latency_ms) do
    timestamp = System.monotonic_time(:millisecond)
    key = {timestamp, :erlang.unique_integer([:monotonic])}

    :ets.insert(@latency_table, {key, latency_ms})

    # Prune old entries beyond window size
    prune_old_entries()

    :ok
  rescue
    ArgumentError ->
      # Table may not exist yet in some edge cases
      :ok
  end

  defp check_system_health do
    # Primary signal: Real p99 from sliding window
    p99 = calculate_p99()

    # Secondary signal: BEAM scheduler utilization
    schedulers = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:total_run_queue_lengths_all)
    scheduler_overloaded = run_queue > schedulers * 2

    cond do
      # P99 exceeds threshold - definitely overloaded
      p99 != nil and p99 > @p99_threshold_ms ->
        {:overloaded, p99}

      # Scheduler pressure but no p99 data yet - use run queue as fallback
      scheduler_overloaded and p99 == nil ->
        {:overloaded, run_queue}

      # Both signals indicate overload
      scheduler_overloaded and p99 != nil and p99 > @p99_threshold_ms * 0.8 ->
        {:overloaded, p99}

      true ->
        :healthy
    end
  end

  defp calculate_p99 do
    try do
      samples =
        :ets.tab2list(@latency_table)
        |> Enum.map(fn {_key, latency} -> latency end)
        |> Enum.sort()

      case length(samples) do
        0 ->
          nil

        n when n < 10 ->
          # Not enough samples for meaningful p99
          nil

        n ->
          # Calculate 99th percentile
          index = round(n * 0.99) - 1
          index = max(0, min(index, n - 1))
          Enum.at(samples, index)
      end
    rescue
      ArgumentError ->
        # Table doesn't exist
        nil
    end
  end

  defp prune_old_entries do
    try do
      size = :ets.info(@latency_table, :size)

      if size > @window_size do
        # Delete oldest entries (lowest keys since ordered_set)
        to_delete = size - @window_size

        :ets.tab2list(@latency_table)
        |> Enum.take(to_delete)
        |> Enum.each(fn {key, _} -> :ets.delete(@latency_table, key) end)
      end
    rescue
      ArgumentError ->
        :ok
    end
  end
end
