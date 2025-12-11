defmodule Mimo.Telemetry.Profiler do
  @moduledoc """
  Profile critical paths to identify bottlenecks (SPEC-061).

  Provides instrumentation for performance-critical operations
  and aggregates timing data for analysis.

  ## Usage

      # Attach profiling handlers (typically in Application.start)
      Mimo.Telemetry.Profiler.attach()

      # Use the profile macro in code
      require Mimo.Telemetry.Profiler
      Mimo.Telemetry.Profiler.profile :memory_search do
        Memory.search(query)
      end

      # Get aggregated stats
      Mimo.Telemetry.Profiler.stats()

      # Get slow operation log
      Mimo.Telemetry.Profiler.slow_operations(threshold_ms: 100)
  """

  use GenServer
  require Logger

  @stats_table :mimo_profile_stats
  @slow_ops_table :mimo_slow_ops
  @slow_threshold_ms 100
  @max_slow_ops 1000

  # ==========================================================================
  # Macros
  # ==========================================================================

  @doc """
  Profile a code block and emit telemetry.

  ## Example

      require Mimo.Telemetry.Profiler

      Mimo.Telemetry.Profiler.profile :memory_search do
        Memory.search_memories(query)
      end
  """
  defmacro profile(name, do: block) do
    quote do
      start = System.monotonic_time(:microsecond)
      result = unquote(block)
      elapsed = System.monotonic_time(:microsecond) - start

      :telemetry.execute(
        [:mimo, :profile, unquote(name)],
        %{duration: elapsed},
        %{name: unquote(name)}
      )

      result
    end
  end

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attach profiling telemetry handlers.
  """
  def attach do
    events = [
      # Memory operations
      [:mimo, :memory, :search],
      [:mimo, :memory, :store],
      [:mimo, :memory, :embedding],

      # HNSW operations
      [:mimo, :hnsw, :search],
      [:mimo, :hnsw, :insert],

      # Embedding generation
      [:mimo, :embedding, :generate],

      # Novelty detection
      [:mimo, :novelty, :classify],

      # Tool dispatch
      [:mimo, :tool, :dispatch],

      # Profile macro events
      [:mimo, :profile, :memory_search],
      [:mimo, :profile, :memory_store],
      [:mimo, :profile, :tool_call],
      [:mimo, :profile, :embedding]
    ]

    :telemetry.attach_many(
      "mimo-profiler",
      events,
      &handle_event/4,
      nil
    )

    Logger.info("[Profiler] Attached to #{length(events)} telemetry events")
    :ok
  end

  @doc """
  Detach profiling handlers.
  """
  def detach do
    :telemetry.detach("mimo-profiler")
  end

  @doc """
  Get aggregated profiling statistics.
  """
  def stats do
    if :ets.whereis(@stats_table) != :undefined do
      :ets.tab2list(@stats_table)
      |> Enum.map(fn {name, count, total_ms, max_ms} ->
        avg_ms = if count > 0, do: Float.round(total_ms / count, 2), else: 0

        %{
          name: name,
          count: count,
          total_ms: Float.round(total_ms, 2),
          avg_ms: avg_ms,
          max_ms: Float.round(max_ms, 2)
        }
      end)
      |> Enum.sort_by(& &1.total_ms, :desc)
    else
      []
    end
  end

  @doc """
  Get recent slow operations.

  ## Options

    * `:threshold_ms` - Minimum duration to consider slow (default: 100)
    * `:limit` - Maximum operations to return (default: 100)
  """
  def slow_operations(opts \\ []) do
    threshold = Keyword.get(opts, :threshold_ms, @slow_threshold_ms)
    limit = Keyword.get(opts, :limit, 100)

    if :ets.whereis(@slow_ops_table) != :undefined do
      :ets.tab2list(@slow_ops_table)
      |> Enum.filter(fn {_id, _name, duration_ms, _ts, _meta} -> duration_ms >= threshold end)
      |> Enum.sort_by(fn {_id, _name, _duration, ts, _meta} -> ts end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_id, name, duration_ms, timestamp, metadata} ->
        %{
          name: name,
          duration_ms: Float.round(duration_ms, 2),
          timestamp: timestamp,
          metadata: metadata
        }
      end)
    else
      []
    end
  end

  @doc """
  Clear all profiling data.
  """
  def clear do
    if :ets.whereis(@stats_table) != :undefined do
      :ets.delete_all_objects(@stats_table)
    end

    if :ets.whereis(@slow_ops_table) != :undefined do
      :ets.delete_all_objects(@slow_ops_table)
    end

    :ok
  end

  @doc """
  Record a profiled operation (used by telemetry handler).
  """
  def record(name, duration_ms, metadata \\ %{}) do
    # Update aggregated stats
    if :ets.whereis(@stats_table) != :undefined do
      # Atomic update: {count, total_ms, max_ms}
      try do
        :ets.update_counter(@stats_table, name, [{2, 1}, {3, duration_ms}], {name, 0, 0, 0})

        # Update max separately (no atomic max operation)
        case :ets.lookup(@stats_table, name) do
          [{^name, _count, _total, current_max}] when duration_ms > current_max ->
            :ets.update_element(@stats_table, name, {4, duration_ms})

          _ ->
            :ok
        end
      rescue
        ArgumentError -> :ok
      end
    end

    # Record slow operations
    if duration_ms >= @slow_threshold_ms and :ets.whereis(@slow_ops_table) != :undefined do
      id = System.unique_integer([:positive])
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      :ets.insert(@slow_ops_table, {id, name, duration_ms, timestamp, metadata})

      # Prune if over limit
      GenServer.cast(__MODULE__, :prune_slow_ops)

      Logger.warning("[SLOW] #{name}: #{Float.round(duration_ms, 2)}ms", metadata)
    end

    :ok
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl GenServer
  def init(_opts) do
    # Create ETS tables
    :ets.new(@stats_table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true}
    ])

    :ets.new(@slow_ops_table, [
      :named_table,
      :public,
      :ordered_set,
      {:write_concurrency, true}
    ])

    Logger.info("[Profiler] Started")
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:prune_slow_ops, state) do
    size = :ets.info(@slow_ops_table, :size)

    if size > @max_slow_ops do
      # Delete oldest entries
      to_delete = size - @max_slow_ops

      :ets.tab2list(@slow_ops_table)
      |> Enum.sort_by(fn {id, _, _, _, _} -> id end)
      |> Enum.take(to_delete)
      |> Enum.each(fn {id, _, _, _, _} -> :ets.delete(@slow_ops_table, id) end)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ==========================================================================
  # Telemetry Handler
  # ==========================================================================

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")

    # Extract duration from various measurement formats
    duration_ms =
      cond do
        Map.has_key?(measurements, :duration) ->
          # Microseconds to milliseconds
          measurements.duration / 1000

        Map.has_key?(measurements, :duration_ms) ->
          measurements.duration_ms

        Map.has_key?(measurements, :latency_ms) ->
          measurements.latency_ms

        true ->
          0
      end

    record(name, duration_ms, metadata)
  end
end
