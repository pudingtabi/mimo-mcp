defmodule Mimo.Cognitive.FeedbackLoop do
  @moduledoc """
  SPEC-074: Cognitive Feedback Loop

  The CRITICAL missing piece that transforms Mimo from "infrastructure that exists"
  to "infrastructure that learns". This module:

  1. CAPTURES outcomes from predictions, classifications, and retrievals
  2. STORES structured feedback in both ETS (fast) and Memory (persistent)
  3. PROVIDES APIs for other modules to query success patterns
  4. ENABLES genuine learning by connecting outcomes to behavior changes

  This is the foundation for:
  - Active Inference to learn what predictions are accurate
  - Meta-Cognitive Router to learn which classifications succeed
  - Sleep Cycle to extract patterns from feedback
  - Emergence to detect genuine capability improvements

  ## Architecture

  ```
  Tool Execution ──► record_outcome() ──► ETS (fast access)
                                      └──► Memory (persistence)
                                      └──► Telemetry (metrics)

  Active Inference ◄── query_patterns(:prediction)
  Router           ◄── query_patterns(:classification)
  Sleep Cycle      ◄── get_recent_feedback()
  ```
  """

  use GenServer
  require Logger

  alias Mimo.Brain.Memory

  # ETS tables for fast access
  @feedback_table :mimo_feedback_outcomes
  @stats_table :mimo_feedback_stats

  # Configuration
  @max_ets_entries 10_000
  @memory_batch_size 100
  @memory_flush_interval_ms 60_000

  # Feedback categories
  @categories [:prediction, :classification, :retrieval, :tool_execution]

  ## Public API

  @doc """
  Records an outcome from a cognitive operation.

  ## Parameters
  - category: :prediction | :classification | :retrieval | :tool_execution
  - context: Map with operation details (query, prediction, classification, etc.)
  - outcome: Map with success status and result details

  ## Example
      FeedbackLoop.record_outcome(:prediction, 
        %{query: "auth patterns", predicted_needs: [:related_code, :past_errors]},
        %{success: true, used: [:related_code], latency_ms: 45}
      )
  """
  @spec record_outcome(atom(), map(), map()) :: :ok
  def record_outcome(category, context, outcome) when category in @categories do
    GenServer.cast(__MODULE__, {:record, category, context, outcome})
  end

  @doc """
  Queries success patterns for a specific category.
  Returns aggregated statistics useful for learning.

  ## Example
      FeedbackLoop.query_patterns(:classification)
      # => %{
      #   total: 150,
      #   success_rate: 0.73,
      #   by_type: %{semantic: 0.82, episodic: 0.68, procedural: 0.71},
      #   recent_trend: :improving
      # }
  """
  @spec query_patterns(atom()) :: map()
  def query_patterns(category) when category in @categories do
    GenServer.call(__MODULE__, {:query_patterns, category})
  end

  @doc """
  Gets recent feedback entries for analysis (used by Sleep Cycle).
  """
  @spec get_recent_feedback(keyword()) :: list(map())
  def get_recent_feedback(opts \\ []) do
    GenServer.call(__MODULE__, {:get_recent, opts})
  end

  @doc """
  Records that a prefetched item was actually used (Active Inference feedback).
  """
  @spec mark_used(String.t(), atom()) :: :ok
  def mark_used(tracking_id, item_type) do
    GenServer.cast(__MODULE__, {:mark_used, tracking_id, item_type})
  end

  @doc """
  Gets the prediction accuracy for Active Inference tuning.
  """
  @spec prediction_accuracy() :: float()
  def prediction_accuracy do
    GenServer.call(__MODULE__, :prediction_accuracy)
  end

  @doc """
  Gets classification success rate by store type.
  """
  @spec classification_accuracy() :: map()
  def classification_accuracy do
    GenServer.call(__MODULE__, :classification_accuracy)
  end

  @doc """
  Returns overall feedback statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@feedback_table, [:named_table, :public, :ordered_set])
    :ets.new(@stats_table, [:named_table, :public, :set])

    # Initialize stats counters
    for category <- @categories do
      :ets.insert(@stats_table, {{category, :total}, 0})
      :ets.insert(@stats_table, {{category, :success}, 0})
    end

    # Schedule periodic memory flush
    schedule_memory_flush()

    state = %{
      pending_memories: [],
      last_flush: System.monotonic_time(:millisecond)
    }

    Logger.info("[FeedbackLoop] SPEC-074 initialized - cognitive learning enabled")
    {:ok, state}
  end

  @impl true
  def handle_cast({:record, category, context, outcome}, state) do
    timestamp = System.system_time(:millisecond)
    tracking_id = generate_tracking_id()

    # Build feedback entry
    entry = %{
      id: tracking_id,
      category: category,
      context: context,
      outcome: outcome,
      timestamp: timestamp,
      success: Map.get(outcome, :success, false)
    }

    # Store in ETS for fast access
    :ets.insert(@feedback_table, {timestamp, entry})

    # Update stats atomically
    :ets.update_counter(@stats_table, {category, :total}, 1)

    if entry.success do
      :ets.update_counter(@stats_table, {category, :success}, 1)
    end

    # Update type-specific stats if available
    update_type_stats(category, context, outcome)

    # Emit telemetry
    :telemetry.execute(
      [:mimo, :feedback, category],
      %{latency_ms: Map.get(outcome, :latency_ms, 0)},
      %{success: entry.success, context: context}
    )

    # Add to pending memories batch
    new_pending = [entry | state.pending_memories]

    # Flush if batch is full
    new_state =
      if length(new_pending) >= @memory_batch_size do
        flush_to_memory(new_pending)
        %{state | pending_memories: [], last_flush: timestamp}
      else
        %{state | pending_memories: new_pending}
      end

    # Prune old ETS entries if needed
    maybe_prune_ets()

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:mark_used, tracking_id, item_type}, state) do
    # Find and update the prediction entry
    case find_by_tracking_id(tracking_id) do
      nil ->
        :ok

      {timestamp, entry} ->
        used_items = Map.get(entry.outcome, :used, [])
        updated_outcome = Map.put(entry.outcome, :used, [item_type | used_items])
        updated_entry = %{entry | outcome: updated_outcome}
        :ets.insert(@feedback_table, {timestamp, updated_entry})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:query_patterns, category}, _from, state) do
    patterns = compute_patterns(category)
    {:reply, patterns, state}
  end

  @impl true
  def handle_call({:get_recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    category = Keyword.get(opts, :category, nil)
    since = Keyword.get(opts, :since, 0)

    entries =
      :ets.tab2list(@feedback_table)
      |> Enum.filter(fn {ts, entry} ->
        ts > since and (is_nil(category) or entry.category == category)
      end)
      |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_, entry} -> entry end)

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:prediction_accuracy, _from, state) do
    accuracy = compute_prediction_accuracy()
    {:reply, accuracy, state}
  end

  @impl true
  def handle_call(:classification_accuracy, _from, state) do
    accuracy = compute_classification_accuracy()
    {:reply, accuracy, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_feedback: count_total(),
      by_category: category_stats(),
      prediction_accuracy: compute_prediction_accuracy(),
      classification_accuracy: compute_classification_accuracy(),
      pending_memories: length(state.pending_memories),
      ets_entries: :ets.info(@feedback_table, :size)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_to_memory, state) do
    if state.pending_memories != [] do
      flush_to_memory(state.pending_memories)
    end

    schedule_memory_flush()
    {:noreply, %{state | pending_memories: [], last_flush: System.monotonic_time(:millisecond)}}
  end

  ## Private Functions

  defp generate_tracking_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp update_type_stats(:classification, context, outcome) do
    store_type = Map.get(context, :classified_as) || Map.get(context, :store_type)

    if store_type do
      key = {:classification_type, store_type}

      # Ensure counter exists
      case :ets.lookup(@stats_table, key) do
        [] -> :ets.insert(@stats_table, {key, %{total: 0, success: 0}})
        _ -> :ok
      end

      # Update atomically using match_spec
      success_inc = if outcome.success, do: 1, else: 0

      :ets.update_element(@stats_table, key, [
        {2,
         fn %{total: t, success: s} -> %{total: t + 1, success: s + success_inc} end
         |> then(fn updater ->
           case :ets.lookup(@stats_table, key) do
             [{^key, current}] -> updater.(current)
             _ -> %{total: 1, success: success_inc}
           end
         end)}
      ])
    end
  end

  defp update_type_stats(:prediction, context, outcome) do
    predicted = Map.get(context, :predicted_needs, [])
    used = Map.get(outcome, :used, [])

    # Track hit rate for each prediction type
    for pred <- predicted do
      key = {:prediction_type, pred}
      hit = if pred in used, do: 1, else: 0

      case :ets.lookup(@stats_table, key) do
        [] ->
          :ets.insert(@stats_table, {key, %{predictions: 1, hits: hit}})

        [{^key, %{predictions: p, hits: h}}] ->
          :ets.insert(@stats_table, {key, %{predictions: p + 1, hits: h + hit}})
      end
    end
  end

  defp update_type_stats(_, _, _), do: :ok

  defp compute_patterns(category) do
    total = get_counter({category, :total})
    success = get_counter({category, :success})

    base = %{
      total: total,
      success_rate: safe_divide(success, total),
      recent_trend: compute_trend(category)
    }

    # Add category-specific patterns
    case category do
      :classification ->
        Map.put(base, :by_type, compute_classification_accuracy())

      :prediction ->
        Map.put(base, :by_type, compute_prediction_by_type())

      _ ->
        base
    end
  end

  defp compute_prediction_accuracy do
    # Get all prediction feedback
    entries =
      :ets.tab2list(@feedback_table)
      |> Enum.filter(fn {_, e} -> e.category == :prediction end)
      |> Enum.take(-100)

    if entries == [] do
      0.5
    else
      hits =
        Enum.count(entries, fn {_, e} ->
          predicted = Map.get(e.context, :predicted_needs, [])
          used = Map.get(e.outcome, :used, [])
          # At least one prediction was used
          Enum.any?(predicted, &(&1 in used))
        end)

      safe_divide(hits, length(entries))
    end
  end

  defp compute_prediction_by_type do
    :ets.tab2list(@stats_table)
    |> Enum.filter(fn
      {{:prediction_type, _}, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:prediction_type, type}, %{predictions: p, hits: h}} ->
      {type, safe_divide(h, p)}
    end)
    |> Map.new()
  end

  defp compute_classification_accuracy do
    :ets.tab2list(@stats_table)
    |> Enum.filter(fn
      {{:classification_type, _}, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:classification_type, type}, %{total: t, success: s}} ->
      {type, safe_divide(s, t)}
    end)
    |> Map.new()
  end

  defp compute_trend(category) do
    # Compare last 50 vs previous 50
    entries =
      :ets.tab2list(@feedback_table)
      |> Enum.filter(fn {_, e} -> e.category == category end)
      |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
      |> Enum.take(100)

    if length(entries) < 20 do
      :insufficient_data
    else
      {recent, older} = Enum.split(entries, 50)

      recent_rate = success_rate(recent)
      older_rate = success_rate(older)

      cond do
        recent_rate > older_rate + 0.05 -> :improving
        recent_rate < older_rate - 0.05 -> :declining
        true -> :stable
      end
    end
  end

  defp success_rate(entries) do
    if entries == [] do
      0.0
    else
      successes = Enum.count(entries, fn {_, e} -> e.success end)
      successes / length(entries)
    end
  end

  defp get_counter(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, count}] when is_integer(count) -> count
      _ -> 0
    end
  end

  defp count_total do
    Enum.reduce(@categories, 0, fn cat, acc ->
      acc + get_counter({cat, :total})
    end)
  end

  defp category_stats do
    for cat <- @categories, into: %{} do
      total = get_counter({cat, :total})
      success = get_counter({cat, :success})
      {cat, %{total: total, success: success, rate: safe_divide(success, total)}}
    end
  end

  defp safe_divide(_, 0), do: 0.0
  defp safe_divide(num, denom), do: num / denom

  defp find_by_tracking_id(tracking_id) do
    :ets.tab2list(@feedback_table)
    |> Enum.find(fn {_, entry} -> entry.id == tracking_id end)
  end

  defp flush_to_memory(entries) do
    # Batch store feedback as memories for persistence
    for entry <- entries do
      content = """
      [Feedback #{entry.category}] #{if entry.success, do: "SUCCESS", else: "FAILURE"}
      Query: #{inspect(Map.get(entry.context, :query, "N/A"))}
      Context: #{inspect(entry.context)}
      Outcome: #{inspect(entry.outcome)}
      """

      Memory.store(%{
        content: String.slice(content, 0, 500),
        category: :observation,
        importance: if(entry.success, do: 0.3, else: 0.5),
        metadata: %{
          type: :feedback,
          feedback_category: entry.category,
          success: entry.success,
          timestamp: entry.timestamp
        }
      })
    end

    Logger.debug("[FeedbackLoop] Flushed #{length(entries)} entries to memory")
  end

  defp maybe_prune_ets do
    size = :ets.info(@feedback_table, :size)

    if size > @max_ets_entries do
      # Remove oldest 20%
      to_remove = div(size, 5)

      :ets.tab2list(@feedback_table)
      |> Enum.sort_by(fn {ts, _} -> ts end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {ts, _} -> :ets.delete(@feedback_table, ts) end)

      Logger.debug("[FeedbackLoop] Pruned #{to_remove} old entries")
    end
  end

  defp schedule_memory_flush do
    Process.send_after(self(), :flush_to_memory, @memory_flush_interval_ms)
  end
end
