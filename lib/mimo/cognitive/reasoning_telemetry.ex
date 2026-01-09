defmodule Mimo.Cognitive.ReasoningTelemetry do
  @moduledoc """
  SPEC-063: Track effectiveness of different reasoning techniques.

  Enables data-driven technique selection by tracking:
  - Success rates per technique
  - Latency per technique
  - Task type distributions
  - Cache hit rates for SELF-DISCOVER

  ## Telemetry Events

  - `[:mimo, :reasoning, :technique]` - When a technique is used
  - `[:mimo, :self_discover, :cache]` - Structure cache hits/misses
  - `[:mimo, :meta_task, :handled]` - Meta-task handling completion

  ## Usage

      # Emit technique usage
      ReasoningTelemetry.emit_technique_used(:self_discover, :solve, true, 1234)
      
      # Get aggregated stats
      stats = ReasoningTelemetry.get_technique_stats()
  """

  require Logger

  # ETS table for tracking stats (simple in-memory aggregation)
  @stats_table :reasoning_telemetry_stats

  @doc """
  Initialize the telemetry stats table.
  Called by application supervisor or on first use.
  """
  def init do
    case :ets.whereis(@stats_table) do
      :undefined ->
        Mimo.EtsSafe.ensure_table(@stats_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Emit telemetry for technique usage.

  ## Parameters

  - `technique` - :self_discover, :rephrase, :self_ask, etc.
  - `operation` - What operation within the technique (e.g., :solve, :discover)
  - `success` - Whether the operation succeeded
  - `duration_ms` - Duration in milliseconds
  """
  @spec emit_technique_used(atom(), atom(), boolean(), non_neg_integer()) :: :ok
  def emit_technique_used(technique, operation, success, duration_ms) do
    init()

    # Emit standard telemetry event
    :telemetry.execute(
      [:mimo, :reasoning, :technique],
      %{duration: duration_ms, success: if(success, do: 1, else: 0)},
      %{technique: technique, operation: operation}
    )

    # Update local stats
    update_stats(technique, operation, success, duration_ms)

    :ok
  end

  @doc """
  Emit telemetry for SELF-DISCOVER structure cache hit/miss.
  """
  @spec emit_structure_cache_hit(boolean()) :: :ok
  def emit_structure_cache_hit(hit?) do
    init()

    :telemetry.execute(
      [:mimo, :self_discover, :cache],
      %{hit: if(hit?, do: 1, else: 0)},
      %{}
    )

    # Update cache stats
    key = {:cache, :self_discover}
    current = get_stat(key) || %{hits: 0, misses: 0}

    updated =
      if hit? do
        Map.update(current, :hits, 1, &(&1 + 1))
      else
        Map.update(current, :misses, 1, &(&1 + 1))
      end

    put_stat(key, updated)

    :ok
  end

  @doc """
  Emit telemetry for meta-task handling completion.
  """
  @spec emit_meta_task_handled(boolean(), atom(), boolean(), non_neg_integer()) :: :ok
  def emit_meta_task_handled(is_meta_task, technique, success, duration_ms) do
    init()

    :telemetry.execute(
      [:mimo, :meta_task, :handled],
      %{duration: duration_ms, success: if(success, do: 1, else: 0)},
      %{is_meta_task: is_meta_task, technique: technique}
    )

    # Update meta-task stats
    key = {:meta_task, if(is_meta_task, do: :meta, else: :standard)}
    current = get_stat(key) || %{count: 0, success: 0, total_duration: 0}

    updated = %{
      count: current.count + 1,
      success: current.success + if(success, do: 1, else: 0),
      total_duration: current.total_duration + duration_ms
    }

    put_stat(key, updated)

    :ok
  end

  @doc """
  Get aggregated statistics for all reasoning techniques.

  Returns a map with stats per technique:
  - success_rate: Percentage of successful operations
  - avg_duration_ms: Average duration in milliseconds
  - count: Total number of operations
  """
  @spec get_technique_stats() :: map()
  def get_technique_stats do
    init()

    techniques = [:self_discover, :rephrase, :self_ask, :combined, :reasoner_fallback]

    techniques
    |> Enum.map(fn technique ->
      stats = get_technique_summary(technique)
      {technique, stats}
    end)
    |> Map.new()
  end

  @doc """
  Get cache statistics for SELF-DISCOVER.
  """
  @spec get_cache_stats() :: map()
  def get_cache_stats do
    init()

    key = {:cache, :self_discover}
    stats = get_stat(key) || %{hits: 0, misses: 0}

    total = stats.hits + stats.misses
    hit_rate = if total > 0, do: stats.hits / total * 100, else: 0.0

    %{
      hits: stats.hits,
      misses: stats.misses,
      total: total,
      hit_rate: Float.round(hit_rate, 2)
    }
  end

  @doc """
  Get meta-task handling statistics.
  """
  @spec get_meta_task_stats() :: map()
  def get_meta_task_stats do
    init()

    meta_stats = get_stat({:meta_task, :meta}) || %{count: 0, success: 0, total_duration: 0}
    standard_stats = get_stat({:meta_task, :standard}) || %{count: 0, success: 0, total_duration: 0}

    %{
      meta_tasks: format_task_stats(meta_stats),
      standard_tasks: format_task_stats(standard_stats),
      total_handled: meta_stats.count + standard_stats.count
    }
  end

  @doc """
  Get a summary of all reasoning telemetry.
  """
  @spec summary() :: map()
  def summary do
    %{
      techniques: get_technique_stats(),
      cache: get_cache_stats(),
      meta_tasks: get_meta_task_stats()
    }
  end

  @doc """
  Reset all statistics (useful for testing).
  """
  @spec reset() :: :ok
  def reset do
    init()
    :ets.delete_all_objects(@stats_table)
    :ok
  end

  defp update_stats(technique, operation, success, duration_ms) do
    key = {:technique, technique, operation}
    current = get_stat(key) || %{count: 0, success: 0, total_duration: 0}

    updated = %{
      count: current.count + 1,
      success: current.success + if(success, do: 1, else: 0),
      total_duration: current.total_duration + duration_ms
    }

    put_stat(key, updated)
  end

  defp get_technique_summary(technique) do
    # Get all operations for this technique
    try do
      :ets.tab2list(@stats_table)
      |> Enum.filter(fn
        {{:technique, ^technique, _}, _} -> true
        _ -> false
      end)
      |> Enum.reduce(%{count: 0, success: 0, total_duration: 0}, fn {_, stats}, acc ->
        %{
          count: acc.count + stats.count,
          success: acc.success + stats.success,
          total_duration: acc.total_duration + stats.total_duration
        }
      end)
      |> format_technique_stats()
    rescue
      ArgumentError -> %{success_rate: 0.0, avg_duration_ms: 0, count: 0}
    end
  end

  defp format_technique_stats(%{count: 0}) do
    %{success_rate: 0.0, avg_duration_ms: 0, count: 0}
  end

  defp format_technique_stats(%{count: count, success: success, total_duration: total}) do
    %{
      success_rate: Float.round(success / count * 100, 2),
      avg_duration_ms: round(total / count),
      count: count
    }
  end

  defp format_task_stats(%{count: 0}) do
    %{count: 0, success_rate: 0.0, avg_duration_ms: 0}
  end

  defp format_task_stats(%{count: count, success: success, total_duration: total}) do
    %{
      count: count,
      success_rate: Float.round(success / count * 100, 2),
      avg_duration_ms: round(total / count)
    }
  end

  defp get_stat(key) do
    try do
      case :ets.lookup(@stats_table, key) do
        [{^key, value}] -> value
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp put_stat(key, value) do
    try do
      :ets.insert(@stats_table, {key, value})
    rescue
      ArgumentError -> :ok
    end
  end
end
