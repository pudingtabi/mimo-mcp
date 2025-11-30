defmodule Mimo.Cognitive.UncertaintyTracker do
  @moduledoc """
  Tracks patterns in uncertainty for meta-learning.

  This GenServer maintains statistics about Mimo's uncertainty patterns,
  identifying topics where Mimo is frequently uncertain and suggesting
  areas for proactive learning.

  ## Features

  - Records uncertainty assessments
  - Identifies recurring knowledge gaps
  - Suggests learning targets
  - Tracks improvement over time
  - Periodic aggregation and cleanup

  ## Usage

      # Record an uncertainty assessment
      UncertaintyTracker.record("authentication", uncertainty)

      # Get topics Mimo is frequently uncertain about
      gaps = UncertaintyTracker.get_knowledge_gaps()

      # Get suggestions for proactive learning
      targets = UncertaintyTracker.suggest_learning_targets()
  """

  use GenServer
  require Logger

  alias Mimo.Cognitive.Uncertainty

  @table :uncertainty_tracker
  @stats_table :uncertainty_stats
  @name __MODULE__

  # Cleanup older than 30 days
  @cleanup_age_days 30
  # Aggregate every hour
  @aggregate_interval_ms 60 * 60 * 1000

  defstruct total_queries: 0,
            high_confidence: 0,
            medium_confidence: 0,
            low_confidence: 0,
            unknown_confidence: 0,
            gaps_detected: 0,
            last_aggregated: nil

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Record an uncertainty assessment.

  ## Parameters

  - `query` - The original query string
  - `uncertainty` - The Uncertainty struct from assessment
  - `outcome` - Optional: What happened after (:answered, :researched, :failed)
  """
  @spec record(String.t(), Uncertainty.t(), atom() | nil) :: :ok
  def record(query, %Uncertainty{} = uncertainty, outcome \\ nil) do
    GenServer.cast(@name, {:record, query, uncertainty, outcome})
  end

  @doc """
  Get topics Mimo is frequently uncertain about.

  Returns topics sorted by frequency of low-confidence assessments.
  """
  @spec get_knowledge_gaps(keyword()) :: [map()]
  def get_knowledge_gaps(opts \\ []) do
    GenServer.call(@name, {:get_gaps, opts})
  end

  @doc """
  Suggest topics for proactive learning.

  Returns topics that would benefit from additional knowledge,
  prioritized by frequency and recency.
  """
  @spec suggest_learning_targets(keyword()) :: [map()]
  def suggest_learning_targets(opts \\ []) do
    GenServer.call(@name, {:suggest_learning, opts})
  end

  @doc """
  Get overall uncertainty statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Get confidence distribution.
  """
  @spec confidence_distribution() :: map()
  def confidence_distribution do
    GenServer.call(@name, :confidence_distribution)
  end

  @doc """
  Clear all tracking data.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(@name, :clear)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables for tracking
    :ets.new(@table, [:named_table, :bag, :public, write_concurrency: true])
    :ets.new(@stats_table, [:named_table, :set, :public, read_concurrency: true])

    # Initialize stats
    :ets.insert(@stats_table, {:global_stats, %__MODULE__{}})

    # Schedule periodic aggregation
    schedule_aggregation()

    {:ok, %{started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:record, query, uncertainty, outcome}, state) do
    now = DateTime.utc_now()

    # Extract topic keywords from query
    topic = extract_topic(query)

    # Store the record
    record = %{
      query: query,
      topic: topic,
      confidence: uncertainty.confidence,
      score: uncertainty.score,
      evidence_count: uncertainty.evidence_count,
      gap_indicators: uncertainty.gap_indicators,
      outcome: outcome,
      recorded_at: now
    }

    :ets.insert(@table, {topic, record})

    # Update global stats
    update_global_stats(uncertainty)

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_gaps, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    min_occurrences = Keyword.get(opts, :min_occurrences, 2)

    gaps =
      @table
      |> :ets.tab2list()
      |> Enum.group_by(fn {topic, _} -> topic end, fn {_, record} -> record end)
      |> Enum.map(fn {topic, records} ->
        low_confidence_count =
          Enum.count(records, fn r -> r.confidence in [:low, :unknown] end)

        avg_score =
          Enum.sum(Enum.map(records, & &1.score)) / max(length(records), 1)

        %{
          topic: topic,
          total_queries: length(records),
          low_confidence_count: low_confidence_count,
          low_confidence_rate: low_confidence_count / max(length(records), 1),
          average_score: avg_score,
          common_gaps: get_common_gaps(records),
          last_queried: Enum.max_by(records, & &1.recorded_at).recorded_at
        }
      end)
      |> Enum.filter(fn g -> g.low_confidence_count >= min_occurrences end)
      |> Enum.sort_by(fn g -> -g.low_confidence_rate end)
      |> Enum.take(limit)

    {:reply, gaps, state}
  end

  @impl true
  def handle_call({:suggest_learning, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 5)

    gaps = get_knowledge_gaps_internal(limit: 20, min_occurrences: 1)

    suggestions =
      gaps
      |> Enum.map(fn gap ->
        priority = calculate_learning_priority(gap)

        %{
          topic: gap.topic,
          priority: priority,
          reason: build_learning_reason(gap),
          query_count: gap.total_queries,
          success_rate: 1.0 - gap.low_confidence_rate,
          suggested_actions: suggest_actions(gap)
        }
      end)
      |> Enum.sort_by(fn s -> -s.priority end)
      |> Enum.take(limit)

    {:reply, suggestions, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    [{:global_stats, stats}] = :ets.lookup(@stats_table, :global_stats)

    total = stats.total_queries

    result = %{
      total_queries: total,
      confidence_distribution: %{
        high: if(total > 0, do: stats.high_confidence / total * 100, else: 0),
        medium: if(total > 0, do: stats.medium_confidence / total * 100, else: 0),
        low: if(total > 0, do: stats.low_confidence / total * 100, else: 0),
        unknown: if(total > 0, do: stats.unknown_confidence / total * 100, else: 0)
      },
      gaps_detected: stats.gaps_detected,
      unique_topics: count_unique_topics(),
      tracking_since: state.started_at
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:confidence_distribution, _from, state) do
    [{:global_stats, stats}] = :ets.lookup(@stats_table, :global_stats)

    dist = %{
      high: stats.high_confidence,
      medium: stats.medium_confidence,
      low: stats.low_confidence,
      unknown: stats.unknown_confidence,
      total: stats.total_queries
    }

    {:reply, dist, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.insert(@stats_table, {:global_stats, %__MODULE__{}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:aggregate, state) do
    do_aggregation()
    schedule_aggregation()
    {:noreply, state}
  end

  # Private functions

  defp extract_topic(query) do
    # Extract meaningful topic from query
    # Remove common question words and keep key terms
    query
    |> String.downcase()
    |> String.replace(
      ~r/\b(how|what|why|when|where|which|who|does|do|is|are|can|could|would|should|the|a|an)\b/,
      ""
    )
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.take(3)
    |> Enum.join("_")
    |> case do
      "" -> "general"
      topic -> topic
    end
  end

  defp update_global_stats(uncertainty) do
    [{:global_stats, stats}] = :ets.lookup(@stats_table, :global_stats)

    new_stats = %{
      stats
      | total_queries: stats.total_queries + 1,
        gaps_detected:
          if(Uncertainty.has_gap?(uncertainty),
            do: stats.gaps_detected + 1,
            else: stats.gaps_detected
          )
    }

    new_stats =
      case uncertainty.confidence do
        :high -> %{new_stats | high_confidence: new_stats.high_confidence + 1}
        :medium -> %{new_stats | medium_confidence: new_stats.medium_confidence + 1}
        :low -> %{new_stats | low_confidence: new_stats.low_confidence + 1}
        :unknown -> %{new_stats | unknown_confidence: new_stats.unknown_confidence + 1}
      end

    :ets.insert(@stats_table, {:global_stats, new_stats})
  end

  defp get_common_gaps(records) do
    records
    |> Enum.flat_map(& &1.gap_indicators)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(3)
    |> Enum.map(fn {gap, count} -> %{gap: gap, count: count} end)
  end

  defp get_knowledge_gaps_internal(opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_occurrences = Keyword.get(opts, :min_occurrences, 2)

    @table
    |> :ets.tab2list()
    |> Enum.group_by(fn {topic, _} -> topic end, fn {_, record} -> record end)
    |> Enum.map(fn {topic, records} ->
      low_confidence_count =
        Enum.count(records, fn r -> r.confidence in [:low, :unknown] end)

      avg_score =
        Enum.sum(Enum.map(records, & &1.score)) / max(length(records), 1)

      %{
        topic: topic,
        total_queries: length(records),
        low_confidence_count: low_confidence_count,
        low_confidence_rate: low_confidence_count / max(length(records), 1),
        average_score: avg_score,
        common_gaps: get_common_gaps(records),
        last_queried: Enum.max_by(records, & &1.recorded_at).recorded_at
      }
    end)
    |> Enum.filter(fn g -> g.low_confidence_count >= min_occurrences end)
    |> Enum.sort_by(fn g -> -g.low_confidence_rate end)
    |> Enum.take(limit)
  end

  defp calculate_learning_priority(gap) do
    # Higher priority for:
    # - High low-confidence rate
    # - More total queries (frequent topic)
    # - Recent queries
    base_priority = gap.low_confidence_rate * 0.4

    frequency_factor = min(gap.total_queries / 10.0, 1.0) * 0.3

    recency_factor =
      case DateTime.diff(DateTime.utc_now(), gap.last_queried, :day) do
        days when days < 1 -> 0.3
        days when days < 7 -> 0.2
        days when days < 30 -> 0.1
        _ -> 0.0
      end

    base_priority + frequency_factor + recency_factor
  end

  defp build_learning_reason(gap) do
    cond do
      gap.low_confidence_rate >= 0.8 ->
        "Very high uncertainty (#{Float.round(gap.low_confidence_rate * 100, 0)}% low confidence)"

      gap.total_queries >= 5 ->
        "Frequently asked topic (#{gap.total_queries} queries)"

      length(gap.common_gaps) > 0 ->
        "Specific gaps identified: #{Enum.map(gap.common_gaps, & &1.gap) |> Enum.join(", ")}"

      true ->
        "Could benefit from additional knowledge"
    end
  end

  defp suggest_actions(gap) do
    actions = []

    actions =
      if Enum.any?(gap.common_gaps, fn g -> String.contains?(g.gap, "documentation") end) do
        ["Fetch relevant library documentation" | actions]
      else
        actions
      end

    actions =
      if Enum.any?(gap.common_gaps, fn g -> String.contains?(g.gap, "code") end) do
        ["Index related code files" | actions]
      else
        actions
      end

    actions =
      if gap.low_confidence_rate >= 0.5 do
        ["Store relevant facts in memory" | actions]
      else
        actions
      end

    case actions do
      [] -> ["Research topic externally"]
      _ -> actions
    end
  end

  defp count_unique_topics do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {topic, _} -> topic end)
    |> Enum.uniq()
    |> length()
  end

  defp do_aggregation do
    # Clean up old records
    cutoff = DateTime.add(DateTime.utc_now(), -@cleanup_age_days, :day)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {topic, record} ->
      if DateTime.compare(record.recorded_at, cutoff) == :lt do
        :ets.delete_object(@table, {topic, record})
      end
    end)

    Logger.debug("[UncertaintyTracker] Aggregation complete")
  end

  defp schedule_aggregation do
    Process.send_after(self(), :aggregate, @aggregate_interval_ms)
  end
end
