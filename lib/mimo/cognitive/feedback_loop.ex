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
  @calibration_table :mimo_confidence_calibration

  # Configuration
  @max_ets_entries 10_000
  @memory_batch_size 100
  @memory_flush_interval_ms 60_000

  # Calibration configuration (L5: Confidence Calibration)
  @min_calibration_samples 20
  # Divide [0,1] into 10 buckets
  @calibration_bucket_count 10
  # Note: @calibration_decay_factor removed - implement time-based decay if needed in future

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

  @doc """
  Get execution statistics for a specific tool.

  Returns success rate and execution count for the given tool,
  useful for experience-based decision making (Phase 3 L3).

  ## Parameters
    - `tool_name` - The tool name (atom or string, e.g., :memory or "memory")

  ## Returns
    Map with:
    - `total` - Total number of executions
    - `success_count` - Number of successful executions
    - `success_rate` - Success rate (0.0 to 1.0)
    - `recent_trend` - :improving, :stable, :declining, or :insufficient_data

  ## Example
      FeedbackLoop.tool_execution_stats(:memory)
      # => %{total: 42, success_count: 38, success_rate: 0.905, recent_trend: :stable}
  """
  @spec tool_execution_stats(atom() | String.t()) :: map()
  def tool_execution_stats(tool_name) do
    GenServer.call(__MODULE__, {:tool_execution_stats, to_string(tool_name)})
  end

  @doc """
  Phase 3 L6: Meta-learning effectiveness analysis.

  Returns insights about how well the learning mechanisms are working,
  enabling introspection about learning itself.

  ## Returns
    Map with:
    - `prediction_effectiveness` - How well predictions match outcomes
    - `classification_effectiveness` - How well classification learning works
    - `tool_learning_effectiveness` - Tool selection learning effectiveness
    - `overall_learning_health` - Aggregate learning health score
    - `recommendations` - Suggested improvements based on patterns

  ## Example
      FeedbackLoop.learning_effectiveness()
      # => %{
      #   prediction_effectiveness: 0.75,
      #   classification_effectiveness: 0.82,
      #   overall_learning_health: :healthy,
      #   recommendations: ["Consider increasing prediction sample size"]
      # }
  """
  @spec learning_effectiveness() :: map()
  def learning_effectiveness do
    GenServer.call(__MODULE__, :learning_effectiveness)
  end

  @doc """
  Query successful patterns for a category.
  Returns high-value success patterns for learning.
  """
  @spec query_success_patterns(atom()) :: [map()]
  def query_success_patterns(category) when category in @categories do
    GenServer.call(__MODULE__, {:query_success_patterns, category})
  end

  # ─────────────────────────────────────────────────────────────────
  # L5: Confidence Calibration API (SPEC-074 extension)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Gets the calibration data for a specific category.

  Calibration data shows how predicted confidence maps to actual success rates.
  Used to adjust confidence scores to better reflect reality.

  ## Parameters
  - category: The feedback category (:prediction, :classification, :retrieval, :tool_execution)

  ## Returns
  Map with:
  - calibration_factor: Multiplier to apply to raw confidence (< 1 = overconfident, > 1 = underconfident)
  - confidence_buckets: Map of confidence ranges to actual success rates
  - sample_count: Total samples used for calibration
  - reliability: :reliable | :insufficient_data | :unreliable
  - recommendation: Human-readable calibration advice

  ## Example
      FeedbackLoop.get_calibration(:classification)
      # => %{
      #   calibration_factor: 0.85,  # System is 15% overconfident
      #   confidence_buckets: %{
      #     "0.9-1.0" => %{predicted: 0.95, actual: 0.81, samples: 42},
      #     "0.8-0.9" => %{predicted: 0.85, actual: 0.79, samples: 38}
      #   },
      #   sample_count: 156,
      #   reliability: :reliable,
      #   recommendation: "Confidence scores are ~15% overconfident. Consider discounting high-confidence predictions."
      # }
  """
  @spec get_calibration(atom()) :: map()
  def get_calibration(category) when category in @categories do
    GenServer.call(__MODULE__, {:get_calibration, category})
  end

  @doc """
  Applies calibration to a raw confidence score.

  Takes a raw confidence value and adjusts it based on historical accuracy
  for the given category. This should be used before presenting confidence
  scores to users or making decisions based on them.

  ## Parameters
  - category: The feedback category
  - raw_confidence: The original confidence score (0.0 to 1.0)

  ## Returns
  - Calibrated confidence score (0.0 to 1.0)

  ## Example
      FeedbackLoop.calibrated_confidence(:classification, 0.95)
      # => 0.81  # Calibrated down because system is overconfident
  """
  @spec calibrated_confidence(atom(), float()) :: float()
  def calibrated_confidence(category, raw_confidence)
      when category in @categories and is_number(raw_confidence) do
    GenServer.call(__MODULE__, {:calibrated_confidence, category, raw_confidence})
  end

  @doc """
  Returns confidence calibration warnings for categories where calibration
  is unreliable or shows significant miscalibration.

  ## Returns
  List of warning maps for categories with calibration issues.

  ## Example
      FeedbackLoop.calibration_warnings()
      # => [
      #   %{category: :prediction, issue: :overconfident, severity: :high,
      #     message: "Prediction confidence is 25% higher than actual success"}
      # ]
  """
  @spec calibration_warnings() :: [map()]
  def calibration_warnings do
    GenServer.call(__MODULE__, :calibration_warnings)
  end

  # ─────────────────────────────────────────────────────────────────
  # Level 2: Behavioral Self-Knowledge (SPEC-SELF-UNDERSTANDING)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Get a summary of today's activities for behavioral self-knowledge.

  Returns a structured summary of what Mimo has done today, enabling
  answers to questions like "What did I do today?" and "How successful was I?"

  ## Parameters
    - opts: Keyword list with optional filters
      - :since - DateTime to start from (default: start of today)
      - :until - DateTime to end at (default: now)

  ## Returns
    Map with:
    - `period` - The time period covered
    - `total_actions` - Total number of actions performed
    - `success_rate` - Overall success rate
    - `by_category` - Breakdown by category (tool_execution, prediction, etc.)
    - `by_tool` - Top tools used with success rates
    - `notable_events` - Significant successes or failures
    - `learning_progress` - Any detected improvements

  ## Example
      FeedbackLoop.daily_activity_summary()
      # => %{
      #   period: %{from: ~U[2025-01-14 00:00:00Z], to: ~U[2025-01-14 15:30:00Z]},
      #   total_actions: 156,
      #   success_rate: 0.87,
      #   by_category: %{tool_execution: 120, prediction: 20, classification: 16},
      #   by_tool: [%{tool: "memory", count: 45, success_rate: 0.93}, ...],
      #   notable_events: [%{type: :success_streak, description: "15 consecutive successful memory operations"}],
      #   learning_progress: %{trend: :improving, improvement: 0.05}
      # }
  """
  @spec daily_activity_summary(keyword()) :: map()
  def daily_activity_summary(opts \\ []) do
    GenServer.call(__MODULE__, {:daily_activity_summary, opts})
  end

  @doc """
  Get a chronological timeline of recent activities.

  Returns a list of actions in chronological order, useful for
  understanding sequence of behavior and decision patterns.

  ## Parameters
    - opts: Keyword list with optional filters
      - :limit - Maximum entries to return (default: 50)
      - :category - Filter by category (default: all)
      - :success_only - Only include successful actions (default: false)
      - :since - Start timestamp (default: last hour)

  ## Returns
    List of activity entries, each with:
    - `timestamp` - When the action occurred
    - `category` - What type of action
    - `tool` - Which tool was used (for tool_execution)
    - `operation` - What operation was performed
    - `success` - Whether it succeeded
    - `duration_ms` - How long it took (if available)

  ## Example
      FeedbackLoop.get_activity_timeline(limit: 10)
      # => [
      #   %{timestamp: ~U[...], category: :tool_execution, tool: "memory", operation: "search", success: true, duration_ms: 45},
      #   %{timestamp: ~U[...], category: :tool_execution, tool: "code", operation: "symbols", success: true, duration_ms: 120},
      #   ...
      # ]
  """
  @spec get_activity_timeline(keyword()) :: [map()]
  def get_activity_timeline(opts \\ []) do
    GenServer.call(__MODULE__, {:get_activity_timeline, opts})
  end

  @doc """
  Get behavioral metrics for self-assessment queries.

  Returns key metrics about Mimo's own behavior that can be used
  by ConfidenceAssessor when answering behavioral self-queries.

  ## Returns
    Map with:
    - `session_activity` - Actions in current session
    - `recent_success_rate` - Success rate in last hour
    - `top_operations` - Most frequent operations
    - `error_patterns` - Recent error types and frequencies
    - `behavioral_consistency` - How consistent behavior has been

  ## Example
      FeedbackLoop.behavioral_metrics()
      # => %{
      #   session_activity: 42,
      #   recent_success_rate: 0.88,
      #   top_operations: ["memory.search", "file.read", "code.symbols"],
      #   error_patterns: [%{type: :timeout, count: 2}],
      #   behavioral_consistency: 0.91
      # }
  """
  @spec behavioral_metrics() :: map()
  def behavioral_metrics do
    GenServer.call(__MODULE__, :behavioral_metrics)
  end

  ## GenServer Implementation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS tables (check if exist to prevent crash on restart)
    if :ets.whereis(@feedback_table) == :undefined do
      :ets.new(@feedback_table, [:named_table, :public, :ordered_set])
    end

    if :ets.whereis(@stats_table) == :undefined do
      :ets.new(@stats_table, [:named_table, :public, :set])
    end

    # L5: Create calibration table for confidence tracking
    # Structure: {{category, bucket}, %{predicted_sum, actual_sum, count}}
    if :ets.whereis(@calibration_table) == :undefined do
      :ets.new(@calibration_table, [:named_table, :public, :set])
    end

    # Initialize stats counters
    for category <- @categories do
      :ets.insert(@stats_table, {{category, :total}, 0})
      :ets.insert(@stats_table, {{category, :success}, 0})
    end

    # L5: Initialize calibration buckets for each category
    for category <- @categories, bucket <- 0..(@calibration_bucket_count - 1) do
      :ets.insert(
        @calibration_table,
        {{category, bucket},
         %{
           predicted_sum: 0.0,
           actual_sum: 0.0,
           count: 0
         }}
      )
    end

    # Schedule periodic memory flush
    schedule_memory_flush()

    state = %{
      pending_memories: [],
      last_flush: System.monotonic_time(:millisecond)
    }

    Logger.info("[FeedbackLoop] SPEC-074 initialized with L5 confidence calibration")
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

    # L5: Update confidence calibration data
    update_calibration_data(category, context, entry.success)

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
  def handle_call({:query_success_patterns, category}, _from, state) do
    patterns = compute_success_patterns(category)
    {:reply, patterns, state}
  end

  @impl true
  def handle_call({:tool_execution_stats, tool_name}, _from, state) do
    stats = compute_tool_execution_stats(tool_name)
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:learning_effectiveness, _from, state) do
    effectiveness = compute_learning_effectiveness()
    {:reply, effectiveness, state}
  end

  # ─────────────────────────────────────────────────────────────────
  # L5: Confidence Calibration Handlers
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:get_calibration, category}, _from, state) do
    calibration = compute_calibration(category)
    {:reply, calibration, state}
  end

  @impl true
  def handle_call({:calibrated_confidence, category, raw_confidence}, _from, state) do
    calibrated = apply_calibration(category, raw_confidence)
    {:reply, calibrated, state}
  end

  @impl true
  def handle_call(:calibration_warnings, _from, state) do
    warnings = compute_calibration_warnings()
    {:reply, warnings, state}
  end

  # ─────────────────────────────────────────────────────────────────
  # Level 2: Behavioral Self-Knowledge Handlers
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:daily_activity_summary, opts}, _from, state) do
    summary = compute_daily_activity_summary(opts)
    {:reply, summary, state}
  end

  @impl true
  def handle_call({:get_activity_timeline, opts}, _from, state) do
    timeline = compute_activity_timeline(opts)
    {:reply, timeline, state}
  end

  @impl true
  def handle_call(:behavioral_metrics, _from, state) do
    metrics = compute_behavioral_metrics()
    {:reply, metrics, state}
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

  # Compute success patterns for learning - returns recent successful entries
  defp compute_success_patterns(category) do
    :ets.tab2list(@feedback_table)
    |> Enum.filter(fn {_, e} -> e.category == category and e.success end)
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(20)
    |> Enum.map(fn {_, entry} ->
      %{
        context: entry.context,
        outcome: entry.outcome,
        timestamp: entry.timestamp,
        confidence: get_in(entry, [:outcome, :confidence]) || 0.0,
        latency_ms: get_in(entry, [:outcome, :latency_ms]) || 0
      }
    end)
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

  # Phase 3 L3: Compute tool-specific execution statistics
  defp compute_tool_execution_stats(tool_name) do
    # Get all tool_execution entries for this tool
    entries =
      :ets.tab2list(@feedback_table)
      |> Enum.filter(fn {_ts, e} ->
        e.category == :tool_execution and
          match_tool_name?(e.context, tool_name)
      end)
      |> Enum.sort_by(fn {ts, _} -> ts end, :desc)

    total = length(entries)
    success_count = Enum.count(entries, fn {_ts, e} -> e.success end)
    success_rate_val = safe_divide(success_count, total)

    # Compute trend (compare last 25 vs previous 25)
    recent_trend =
      if total < 10 do
        :insufficient_data
      else
        {recent, older} = Enum.split(entries, min(25, div(total, 2)))

        if older == [] do
          :insufficient_data
        else
          recent_rate = Enum.count(recent, fn {_, e} -> e.success end) / length(recent)
          older_rate = Enum.count(older, fn {_, e} -> e.success end) / length(older)

          cond do
            recent_rate > older_rate + 0.05 -> :improving
            recent_rate < older_rate - 0.05 -> :declining
            true -> :stable
          end
        end
      end

    %{
      tool: tool_name,
      total: total,
      success_count: success_count,
      success_rate: Float.round(success_rate_val, 3),
      recent_trend: recent_trend
    }
  end

  # Match tool name in context (handles both atom and string keys)
  defp match_tool_name?(context, tool_name) when is_map(context) do
    context_tool = context[:tool] || context["tool"]
    to_string(context_tool) == to_string(tool_name)
  end

  defp match_tool_name?(_, _), do: false

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
    # SPEC-074-ENHANCED: Balanced learning - store failures + sampled high-value successes
    important_entries = select_important_entries(entries)

    if important_entries == [] do
      Logger.debug("[FeedbackLoop] No important entries to store (#{length(entries)} total)")
      :ok
    else
      for entry <- important_entries do
        status = if entry.success, do: "SUCCESS", else: "FAILURE"

        content = """
        [Feedback #{entry.category}] #{status}
        Query: #{inspect(Map.get(entry.context, :query, "N/A"))}
        Context: #{inspect(entry.context)}
        Outcome: #{inspect(entry.outcome)}
        """

        importance = if entry.success, do: 0.7, else: 0.6

        Memory.store(%{
          content: String.slice(content, 0, 500),
          category: :observation,
          importance: importance,
          metadata: %{
            type: :feedback,
            feedback_category: entry.category,
            success: entry.success,
            timestamp: entry.timestamp
          }
        })
      end

      success_count = Enum.count(important_entries, & &1.success)
      failure_count = length(important_entries) - success_count

      Logger.debug(
        "[FeedbackLoop] Stored #{failure_count} failures + #{success_count} high-value successes"
      )
    end
  end

  # Select entries for memory storage: all failures + sampled valuable successes
  defp select_important_entries(entries) do
    failures = Enum.filter(entries, &(not &1.success))

    # Sample successes: high confidence (>0.8) or novel patterns
    # Limit to 10% of batch to prevent memory bloat
    max_successes = max(div(length(entries), 10), 1)

    valuable_successes =
      entries
      |> Enum.filter(& &1.success)
      |> Enum.filter(&is_valuable_success?/1)
      |> Enum.take(max_successes)

    failures ++ valuable_successes
  end

  # Determine if a success is valuable enough to store
  defp is_valuable_success?(entry) do
    confidence = get_in(entry, [:outcome, :confidence]) || 0.0
    latency = get_in(entry, [:outcome, :latency_ms]) || 0

    # High confidence outcomes are valuable
    high_confidence = confidence > 0.8

    # Fast executions with success suggest good patterns
    fast_success = latency < 100 and confidence > 0.6

    # Novel patterns (detected by category combinations)
    novel = is_novel_pattern?(entry)

    high_confidence or fast_success or novel
  end

  # Check if this is a novel pattern worth preserving
  defp is_novel_pattern?(entry) do
    key = {:success_pattern, entry.category}

    case :ets.lookup(@stats_table, key) do
      [] ->
        # First success in this category - definitely novel
        :ets.insert(@stats_table, {key, 1})
        true

      [{^key, count}] when count < 5 ->
        # Still building baseline - capture early patterns
        :ets.insert(@stats_table, {key, count + 1})
        true

      _ ->
        # Have enough examples, only store if other criteria met
        false
    end
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

  # Phase 3 L6: Compute meta-learning effectiveness
  defp compute_learning_effectiveness do
    # Get current stats for each learning mechanism
    prediction_acc = compute_prediction_accuracy()
    classification_acc = compute_classification_accuracy()

    # Get trend data
    prediction_trend = compute_trend(:prediction)
    classification_trend = compute_trend(:classification)
    tool_trend = compute_trend(:tool_execution)

    # Analyze tool learning across all tools
    tool_entries =
      :ets.tab2list(@feedback_table)
      |> Enum.filter(fn {_ts, e} -> e.category == :tool_execution end)

    tool_success_rate =
      if tool_entries == [] do
        0.0
      else
        successes = Enum.count(tool_entries, fn {_ts, e} -> e.success end)
        successes / length(tool_entries)
      end

    # Compute overall health
    overall_health = compute_overall_health(prediction_acc, classification_acc, tool_success_rate)

    # Generate recommendations
    recommendations =
      generate_learning_recommendations(
        prediction_acc,
        prediction_trend,
        classification_acc,
        classification_trend,
        tool_success_rate,
        tool_trend
      )

    %{
      prediction_effectiveness: Float.round(prediction_acc, 3),
      classification_effectiveness: classification_acc |> Map.values() |> average_or_zero(),
      tool_learning_effectiveness: Float.round(tool_success_rate, 3),
      trends: %{
        prediction: prediction_trend,
        classification: classification_trend,
        tool_execution: tool_trend
      },
      overall_learning_health: overall_health,
      total_feedback_entries: :ets.info(@feedback_table, :size),
      recommendations: recommendations
    }
  end

  defp compute_overall_health(pred_acc, class_acc, tool_rate) do
    class_avg = class_acc |> Map.values() |> average_or_zero()
    overall = (pred_acc + class_avg + tool_rate) / 3

    cond do
      overall >= 0.8 -> :excellent
      overall >= 0.6 -> :healthy
      overall >= 0.4 -> :needs_attention
      overall > 0 -> :struggling
      true -> :no_data
    end
  end

  defp average_or_zero([]), do: 0.0
  defp average_or_zero(list), do: Float.round(Enum.sum(list) / length(list), 3)

  defp generate_learning_recommendations(
         pred_acc,
         pred_trend,
         _class_acc,
         class_trend,
         tool_rate,
         tool_trend
       ) do
    recommendations = []

    recommendations =
      if pred_acc < 0.5 and pred_trend != :improving do
        ["Prediction accuracy is low - consider reviewing prediction logic" | recommendations]
      else
        recommendations
      end

    recommendations =
      if class_trend == :declining do
        ["Classification accuracy is declining - review recent changes" | recommendations]
      else
        recommendations
      end

    recommendations =
      if tool_rate < 0.7 and tool_trend != :improving do
        [
          "Tool execution success rate is low - consider tool selection improvements"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if :ets.info(@feedback_table, :size) < 50 do
        ["Insufficient feedback data for reliable learning - need more samples" | recommendations]
      else
        recommendations
      end

    if recommendations == [] do
      ["Learning systems are operating normally"]
    else
      Enum.reverse(recommendations)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # L5: Confidence Calibration Implementation
  # ─────────────────────────────────────────────────────────────────

  # Updates calibration data when an outcome is recorded.
  # Extracts predicted confidence from context and updates the appropriate bucket.
  defp update_calibration_data(category, context, success) do
    # Extract predicted confidence from various context keys
    predicted_confidence = extract_confidence(context)

    if predicted_confidence do
      # Determine which bucket this confidence falls into
      bucket = confidence_to_bucket(predicted_confidence)
      actual_value = if success, do: 1.0, else: 0.0

      # Atomically update the bucket
      case :ets.lookup(@calibration_table, {category, bucket}) do
        [{_key, data}] ->
          updated_data = %{
            predicted_sum: data.predicted_sum + predicted_confidence,
            actual_sum: data.actual_sum + actual_value,
            count: data.count + 1
          }

          :ets.insert(@calibration_table, {{category, bucket}, updated_data})

        [] ->
          # Initialize if not exists (shouldn't happen with proper init)
          :ets.insert(
            @calibration_table,
            {{category, bucket},
             %{
               predicted_sum: predicted_confidence,
               actual_sum: actual_value,
               count: 1
             }}
          )
      end
    end
  end

  # Extracts confidence score from context map
  defp extract_confidence(context) do
    context[:predicted_confidence] ||
      context[:confidence] ||
      context["predicted_confidence"] ||
      context["confidence"] ||
      get_in(context, [:scores, :confidence]) ||
      get_in(context, [:classification, :confidence])
  end

  # Converts a confidence score (0.0-1.0) to a bucket index (0-9)
  defp confidence_to_bucket(confidence) when confidence >= 0 and confidence <= 1 do
    bucket = trunc(confidence * @calibration_bucket_count)
    min(bucket, @calibration_bucket_count - 1)
  end

  # Default to middle bucket
  defp confidence_to_bucket(_), do: 5

  # Converts bucket index back to confidence range string
  defp bucket_to_range(bucket) do
    low = bucket / @calibration_bucket_count
    high = (bucket + 1) / @calibration_bucket_count
    "#{Float.round(low, 1)}-#{Float.round(high, 1)}"
  end

  # Computes calibration data for a category
  defp compute_calibration(category) do
    # Gather all bucket data
    buckets_data =
      0..(@calibration_bucket_count - 1)
      |> Enum.map(fn bucket ->
        case :ets.lookup(@calibration_table, {category, bucket}) do
          [{_key, data}] -> {bucket, data}
          [] -> {bucket, %{predicted_sum: 0.0, actual_sum: 0.0, count: 0}}
        end
      end)
      |> Enum.filter(fn {_bucket, data} -> data.count > 0 end)

    total_count = Enum.reduce(buckets_data, 0, fn {_b, d}, acc -> acc + d.count end)

    # Build bucket summary
    confidence_buckets =
      buckets_data
      |> Enum.map(fn {bucket, data} ->
        avg_predicted = if data.count > 0, do: data.predicted_sum / data.count, else: 0.0
        avg_actual = if data.count > 0, do: data.actual_sum / data.count, else: 0.0

        {bucket_to_range(bucket),
         %{
           predicted: Float.round(avg_predicted, 3),
           actual: Float.round(avg_actual, 3),
           samples: data.count,
           error: Float.round(avg_predicted - avg_actual, 3)
         }}
      end)
      |> Map.new()

    # Compute overall calibration factor
    {calibration_factor, reliability} = compute_calibration_factor(buckets_data, total_count)

    # Generate recommendation
    recommendation =
      generate_calibration_recommendation(calibration_factor, reliability, buckets_data)

    %{
      calibration_factor: Float.round(calibration_factor, 3),
      confidence_buckets: confidence_buckets,
      sample_count: total_count,
      reliability: reliability,
      recommendation: recommendation
    }
  end

  # Computes the overall calibration factor
  defp compute_calibration_factor(buckets_data, total_count) do
    if total_count < @min_calibration_samples do
      {1.0, :insufficient_data}
    else
      # Weighted average of predicted vs actual
      {total_predicted, total_actual} =
        Enum.reduce(buckets_data, {0.0, 0.0}, fn {_b, data}, {pred, act} ->
          {pred + data.predicted_sum, act + data.actual_sum}
        end)

      if total_predicted > 0 do
        # calibration_factor = actual / predicted
        # < 1 means overconfident, > 1 means underconfident
        factor = total_actual / total_predicted
        reliability = if total_count >= @min_calibration_samples * 2, do: :reliable, else: :moderate
        {factor, reliability}
      else
        {1.0, :insufficient_data}
      end
    end
  end

  # Generates a human-readable calibration recommendation
  defp generate_calibration_recommendation(factor, reliability, _buckets_data) do
    case reliability do
      :insufficient_data ->
        "Not enough data for calibration. Need at least #{@min_calibration_samples} samples."

      _ ->
        cond do
          factor < 0.75 ->
            deviation = round((1 - factor) * 100)

            "System is significantly overconfident (~#{deviation}%). High-confidence predictions often fail."

          factor < 0.90 ->
            deviation = round((1 - factor) * 100)

            "System is moderately overconfident (~#{deviation}%). Consider discounting confidence scores."

          factor > 1.25 ->
            deviation = round((factor - 1) * 100)

            "System is significantly underconfident (~#{deviation}%). Confidence scores are too conservative."

          factor > 1.10 ->
            deviation = round((factor - 1) * 100)
            "System is slightly underconfident (~#{deviation}%). Could trust predictions more."

          true ->
            "Confidence calibration is good. Predicted confidence matches actual success rates."
        end
    end
  end

  # Applies calibration to a raw confidence score
  defp apply_calibration(category, raw_confidence) do
    # Get the bucket for this confidence
    bucket = confidence_to_bucket(raw_confidence)

    # Get bucket-specific calibration if available
    case :ets.lookup(@calibration_table, {category, bucket}) do
      [{_key, data}] when data.count >= 5 ->
        # Use bucket-specific calibration
        if data.predicted_sum > 0 do
          bucket_factor = data.actual_sum / data.predicted_sum
          calibrated = raw_confidence * bucket_factor
          # Clamp to [0, 1]
          max(0.0, min(1.0, calibrated))
        else
          raw_confidence
        end

      _ ->
        # Fall back to category-wide calibration
        calibration = compute_calibration(category)

        if calibration.reliability != :insufficient_data do
          calibrated = raw_confidence * calibration.calibration_factor
          max(0.0, min(1.0, calibrated))
        else
          raw_confidence
        end
    end
  end

  # Computes calibration warnings for all categories
  defp compute_calibration_warnings do
    @categories
    |> Enum.map(fn category ->
      calibration = compute_calibration(category)
      {category, calibration}
    end)
    |> Enum.filter(fn {_category, cal} ->
      cal.reliability != :insufficient_data and
        (cal.calibration_factor < 0.85 or cal.calibration_factor > 1.15)
    end)
    |> Enum.map(fn {category, cal} ->
      {issue, severity} =
        cond do
          cal.calibration_factor < 0.75 -> {:severely_overconfident, :high}
          cal.calibration_factor < 0.85 -> {:overconfident, :medium}
          cal.calibration_factor > 1.25 -> {:severely_underconfident, :high}
          cal.calibration_factor > 1.15 -> {:underconfident, :medium}
          true -> {:normal, :low}
        end

      deviation = abs(round((cal.calibration_factor - 1.0) * 100))

      %{
        category: category,
        issue: issue,
        severity: severity,
        calibration_factor: cal.calibration_factor,
        sample_count: cal.sample_count,
        message: generate_warning_message(category, issue, deviation)
      }
    end)
  end

  defp generate_warning_message(category, issue, deviation) do
    case issue do
      :severely_overconfident ->
        "#{category} confidence is #{deviation}% higher than actual success rate - significant overconfidence"

      :overconfident ->
        "#{category} confidence is #{deviation}% higher than actual success - moderate overconfidence"

      :severely_underconfident ->
        "#{category} confidence is #{deviation}% lower than actual success rate - significant underconfidence"

      :underconfident ->
        "#{category} confidence is #{deviation}% lower than actual success - moderate underconfidence"

      _ ->
        "#{category} calibration is within acceptable range"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Level 2: Behavioral Self-Knowledge Private Functions
  # ─────────────────────────────────────────────────────────────────

  defp compute_daily_activity_summary(opts) do
    now = DateTime.utc_now()

    # Default to start of today (midnight UTC)
    default_since =
      now
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    since = Keyword.get(opts, :since, default_since)
    until_time = Keyword.get(opts, :until, now)

    # Get all entries from ETS within the time range
    entries = get_entries_in_range(since, until_time)

    # Calculate statistics
    total_actions = length(entries)
    successes = Enum.count(entries, fn {_ts, entry} -> entry.outcome.success end)
    success_rate = if total_actions > 0, do: successes / total_actions, else: 0.0

    # Group by category
    by_category =
      entries
      |> Enum.group_by(fn {_ts, entry} -> entry.category end)
      |> Enum.map(fn {cat, items} -> {cat, length(items)} end)
      |> Map.new()

    # Group by tool (for tool_execution category)
    by_tool =
      entries
      |> Enum.filter(fn {_ts, entry} -> entry.category == :tool_execution end)
      |> Enum.group_by(fn {_ts, entry} -> extract_tool_name(entry) end)
      |> Enum.map(fn {tool, items} ->
        tool_successes = Enum.count(items, fn {_key, e} -> e.outcome.success end)

        %{
          tool: tool,
          count: length(items),
          success_rate: if(length(items) > 0, do: tool_successes / length(items), else: 0.0)
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(10)

    # Detect notable events
    notable_events = detect_notable_events(entries)

    # Calculate learning progress (compare first half to second half)
    learning_progress = compute_learning_progress(entries)

    %{
      period: %{from: since, to: until_time},
      total_actions: total_actions,
      success_rate: Float.round(success_rate, 3),
      by_category: by_category,
      by_tool: by_tool,
      notable_events: notable_events,
      learning_progress: learning_progress
    }
  end

  defp compute_activity_timeline(opts) do
    limit = Keyword.get(opts, :limit, 50)
    category_filter = Keyword.get(opts, :category)
    success_only = Keyword.get(opts, :success_only, false)

    # Default to last hour
    default_since = DateTime.add(DateTime.utc_now(), -3600, :second)
    since = Keyword.get(opts, :since, default_since)

    # Get entries from ETS
    entries = get_entries_in_range(since, DateTime.utc_now())

    entries
    |> Enum.map(fn {_ts, entry} -> entry end)
    |> maybe_filter_category(category_filter)
    |> maybe_filter_success(success_only)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_timeline_entry/1)
  end

  defp compute_behavioral_metrics do
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)

    # Get recent entries
    recent_entries = get_entries_in_range(one_hour_ago, now)

    # Session activity (approximate - entries in last hour)
    session_activity = length(recent_entries)

    # Recent success rate
    recent_successes = Enum.count(recent_entries, fn {_ts, entry} -> entry.outcome.success end)

    recent_success_rate =
      if session_activity > 0, do: recent_successes / session_activity, else: 0.0

    # Top operations
    top_operations =
      recent_entries
      |> Enum.map(fn {_ts, entry} -> extract_operation_name(entry) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_op, count} -> count end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {op, _count} -> op end)

    # Error patterns
    error_patterns =
      recent_entries
      |> Enum.filter(fn {_ts, entry} -> not entry.outcome.success end)
      |> Enum.map(fn {_ts, entry} -> extract_error_type(entry) end)
      |> Enum.frequencies()
      |> Enum.map(fn {type, count} -> %{type: type, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(5)

    # Behavioral consistency (standard deviation of success over time windows)
    behavioral_consistency = compute_behavioral_consistency(recent_entries)

    %{
      session_activity: session_activity,
      recent_success_rate: Float.round(recent_success_rate, 3),
      top_operations: top_operations,
      error_patterns: error_patterns,
      behavioral_consistency: Float.round(behavioral_consistency, 3)
    }
  end

  # Helper functions for behavioral self-knowledge

  defp get_entries_in_range(since, until_time) do
    since_ms = DateTime.to_unix(since, :millisecond)
    until_ms = DateTime.to_unix(until_time, :millisecond)

    # ETS ordered_set with timestamp as key allows range queries
    # Entries are stored as {timestamp, entry}
    :ets.foldl(
      fn {ts, entry}, acc ->
        if ts >= since_ms and ts <= until_ms do
          [{ts, entry} | acc]
        else
          acc
        end
      end,
      [],
      @feedback_table
    )
  end

  defp extract_tool_name(entry) do
    cond do
      is_binary(Map.get(entry.context, :tool)) -> entry.context.tool
      is_atom(Map.get(entry.context, :tool)) -> Atom.to_string(entry.context.tool)
      is_binary(Map.get(entry.context, :tool_name)) -> entry.context.tool_name
      true -> "unknown"
    end
  end

  defp extract_operation_name(entry) do
    tool = extract_tool_name(entry)
    operation = Map.get(entry.context, :operation, "execute")
    "#{tool}.#{operation}"
  end

  defp extract_error_type(entry) do
    cond do
      Map.has_key?(entry.outcome, :error_type) -> entry.outcome.error_type
      Map.has_key?(entry.outcome, :error) -> categorize_error(entry.outcome.error)
      true -> :unknown
    end
  end

  defp categorize_error(error) when is_binary(error) do
    cond do
      String.contains?(error, "timeout") -> :timeout
      String.contains?(error, "not found") -> :not_found
      String.contains?(error, "permission") -> :permission
      String.contains?(error, "connection") -> :connection
      true -> :other
    end
  end

  defp categorize_error(_), do: :unknown

  defp detect_notable_events(entries) do
    events = []

    # Detect success streaks
    success_streak = count_max_success_streak(entries)

    events =
      if success_streak >= 10 do
        [
          %{
            type: :success_streak,
            description: "#{success_streak} consecutive successful operations"
          }
          | events
        ]
      else
        events
      end

    # Detect failure clusters
    failure_count = Enum.count(entries, fn {_key, e} -> not e.outcome.success end)

    events =
      if failure_count >= 5 and length(entries) > 10 do
        failure_rate = failure_count / length(entries)

        if failure_rate > 0.3 do
          [
            %{
              type: :high_failure_rate,
              description: "#{round(failure_rate * 100)}% failure rate detected"
            }
            | events
          ]
        else
          events
        end
      else
        events
      end

    Enum.reverse(events)
  end

  defp count_max_success_streak(entries) do
    entries
    |> Enum.sort_by(fn {ts, _} -> ts end)
    |> Enum.map(fn {_ts, entry} -> entry.outcome.success end)
    |> Enum.chunk_by(& &1)
    |> Enum.filter(fn chunk -> hd(chunk) == true end)
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp compute_learning_progress(entries) when length(entries) < 10 do
    %{trend: :insufficient_data, improvement: 0.0}
  end

  defp compute_learning_progress(entries) do
    sorted = Enum.sort_by(entries, fn {ts, _} -> ts end)
    mid = div(length(sorted), 2)
    {first_half, second_half} = Enum.split(sorted, mid)

    first_rate = success_rate_for(first_half)
    second_rate = success_rate_for(second_half)
    improvement = second_rate - first_rate

    trend =
      cond do
        improvement > 0.05 -> :improving
        improvement < -0.05 -> :declining
        true -> :stable
      end

    %{trend: trend, improvement: Float.round(improvement, 3)}
  end

  defp success_rate_for([]), do: 0.0

  defp success_rate_for(entries) do
    successes = Enum.count(entries, fn {_key, e} -> e.outcome.success end)
    successes / length(entries)
  end

  defp maybe_filter_category(entries, nil), do: entries
  defp maybe_filter_category(entries, cat), do: Enum.filter(entries, &(&1.category == cat))

  defp maybe_filter_success(entries, false), do: entries
  defp maybe_filter_success(entries, true), do: Enum.filter(entries, & &1.outcome.success)

  defp format_timeline_entry(entry) do
    %{
      timestamp: entry.timestamp,
      category: entry.category,
      tool: extract_tool_name(entry),
      operation: Map.get(entry.context, :operation, "unknown"),
      success: entry.outcome.success,
      duration_ms: Map.get(entry.outcome, :latency_ms) || Map.get(entry.outcome, :duration_ms)
    }
  end

  defp compute_behavioral_consistency(entries) when length(entries) < 5 do
    # Not enough data, assume consistent
    1.0
  end

  defp compute_behavioral_consistency(entries) do
    # Divide into 5 time windows and compute success rate variance
    sorted = Enum.sort_by(entries, fn {ts, _} -> ts end)
    chunk_size = max(1, div(length(sorted), 5))

    rates =
      sorted
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(&success_rate_for/1)

    if length(rates) < 2 do
      1.0
    else
      mean = Enum.sum(rates) / length(rates)

      variance =
        rates
        |> Enum.map(fn r -> (r - mean) * (r - mean) end)
        |> Enum.sum()
        |> Kernel./(length(rates))

      std_dev = :math.sqrt(variance)

      # Convert to consistency score (lower std_dev = higher consistency)
      # Max expected std_dev is 0.5 (all rates either 0 or 1)
      max(0.0, 1.0 - std_dev * 2)
    end
  end
end
