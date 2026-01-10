defmodule Mimo.Cognitive.MetacognitiveMonitor do
  @moduledoc """
  Level 4 Self-Understanding: Metacognitive Monitoring.

  Tracks and explains WHY decisions are made, not just WHAT decisions.
  Enables "decision archaeology" - explaining reasoning after the fact.

  ## Features

  1. **Decision Tracing**: Records strategy selections, step evaluations, branches
  2. **Causal Explanation**: Explains why specific decisions were made
  3. **Cognitive Load Detection**: Monitors for overload indicators
  4. **Session Analysis**: Full reasoning trace for any session

  ## Usage

      # Record when strategy is selected (called from Reasoner)
      MetacognitiveMonitor.record_strategy_decision(session_id, strategy, %{
        problem_complexity: :complex,
        involves_tools: true,
        similar_problems_found: 3,
        reason: "ToT recommended for complex ambiguous problem"
      })

      # Later, explain that decision
      {:ok, explanation} = MetacognitiveMonitor.explain_session(session_id)
      # => "Strategy :tot was selected because: ToT recommended for complex..."

      # Check cognitive load
      {:ok, load} = MetacognitiveMonitor.cognitive_load()
      # => %{level: :normal, active_sessions: 2, indicators: [...]}

  ## SPEC-SELF-UNDERSTANDING Level 4

  This module implements the "Causal Self-Understanding" level, enabling
  Mimo to answer questions like:
  - "Why did you choose CoT over ToT?"
  - "What influenced that decision?"
  - "Show me the reasoning trace"
  """
  use GenServer
  require Logger

  @table :mimo_decision_traces
  # 4 hour TTL for decision traces
  @ttl_ms 4 * 3_600_000
  # Cleanup every 30 minutes
  @cleanup_interval_ms 30 * 60_000

  # Cognitive load thresholds
  @high_load_sessions 10
  @critical_load_sessions 20
  @high_error_rate 0.3
  # Future: use for detecting long-running sessions
  # @long_session_threshold_ms 60_000

  @type decision_type :: :strategy_selection | :step_evaluation | :branch_choice | :backtrack
  @type load_level :: :low | :normal | :high | :critical

  @type decision :: %{
          decision_id: String.t(),
          session_id: String.t(),
          decision_type: decision_type(),
          choice: term(),
          alternatives: [term()],
          factors: map(),
          reason: String.t(),
          context: map(),
          timestamp: DateTime.t()
        }

  @type load_status :: %{
          level: load_level(),
          active_sessions: non_neg_integer(),
          avg_session_duration_ms: float(),
          backtrack_rate: float(),
          error_rate: float(),
          indicators: [String.t()]
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a strategy selection decision.

  Called from Reasoner.start/2 after strategy is chosen.

  ## Parameters
  - session_id: The reasoning session ID
  - strategy: The selected strategy (:cot, :tot, :react, :reflexion)
  - context: Map containing decision factors
    - :problem_complexity
    - :involves_tools
    - :similar_problems_found
    - :reason (string explanation)
    - :alternatives (list of considered alternatives)
  """
  @spec record_strategy_decision(String.t(), atom(), map()) :: :ok
  def record_strategy_decision(session_id, strategy, context \\ %{}) do
    decision = %{
      decision_id: generate_id("strat"),
      session_id: session_id,
      decision_type: :strategy_selection,
      choice: strategy,
      alternatives: context[:alternatives] || [:cot, :tot, :react, :reflexion],
      factors: extract_factors(context),
      reason: context[:reason] || "No reason provided",
      context: context,
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:record_decision, decision})
  end

  @doc """
  Record a step/thought evaluation decision.

  Called when a reasoning step is evaluated as good/bad/maybe.
  """
  @spec record_step_evaluation(String.t(), String.t(), map()) :: :ok
  def record_step_evaluation(session_id, step_id, evaluation_context) do
    decision = %{
      decision_id: generate_id("step"),
      session_id: session_id,
      decision_type: :step_evaluation,
      choice: evaluation_context[:evaluation] || :unknown,
      alternatives: [:good, :maybe, :bad],
      factors: %{
        confidence: evaluation_context[:confidence] || 0.5,
        coherence: evaluation_context[:coherence] || 0.5
      },
      reason: evaluation_context[:feedback] || "Step evaluated",
      context: Map.put(evaluation_context, :step_id, step_id),
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:record_decision, decision})
  end

  @doc """
  Record a branch creation decision (ToT).

  Called when a new reasoning branch is created.
  """
  @spec record_branch_choice(String.t(), String.t(), map()) :: :ok
  def record_branch_choice(session_id, branch_id, context \\ %{}) do
    decision = %{
      decision_id: generate_id("brch"),
      session_id: session_id,
      decision_type: :branch_choice,
      choice: :create_branch,
      alternatives: [:continue_current, :create_branch, :backtrack],
      factors: %{
        exploration_depth: context[:depth] || 0,
        total_branches: context[:total_branches] || 1,
        branch_evaluation: context[:evaluation] || :uncertain
      },
      reason: context[:reason] || "Exploring alternative approach",
      context: Map.put(context, :branch_id, branch_id),
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:record_decision, decision})
  end

  @doc """
  Record a backtrack decision (ToT).

  Called when reasoning backtracks from a dead-end branch.
  """
  @spec record_backtrack(String.t(), String.t(), map()) :: :ok
  def record_backtrack(session_id, from_branch_id, context \\ %{}) do
    decision = %{
      decision_id: generate_id("back"),
      session_id: session_id,
      decision_type: :backtrack,
      choice: :backtrack,
      alternatives: [:continue, :backtrack],
      factors: %{
        branch_confidence: context[:confidence] || 0.0,
        dead_end_detected: true
      },
      reason: context[:reason] || "Branch led to dead end",
      context: Map.put(context, :from_branch_id, from_branch_id),
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:record_decision, decision})
  end

  @doc """
  Explain a specific session's decisions.

  Returns a structured explanation of all decisions made during the session.
  """
  @spec explain_session(String.t()) :: {:ok, map()} | {:error, :not_found}
  def explain_session(session_id) do
    GenServer.call(__MODULE__, {:explain_session, session_id})
  end

  @doc """
  Explain a specific decision by ID.
  """
  @spec explain_decision(String.t()) :: {:ok, map()} | {:error, :not_found}
  def explain_decision(decision_id) do
    GenServer.call(__MODULE__, {:explain_decision, decision_id})
  end

  @doc """
  Get the raw decision trace for a session.
  """
  @spec get_trace(String.t()) :: {:ok, [decision()]} | {:error, :not_found}
  def get_trace(session_id) do
    GenServer.call(__MODULE__, {:get_trace, session_id})
  end

  @doc """
  Assess current cognitive load.

  Returns indicators of potential cognitive overload.
  """
  @spec cognitive_load() :: {:ok, load_status()}
  def cognitive_load do
    GenServer.call(__MODULE__, :cognitive_load)
  end

  @doc """
  Get statistics about decision tracking.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table =
      case Mimo.EtsHeirManager.reclaim_table(@table, self()) do
        {:ok, reclaimed_table} ->
          Logger.info("[MetacognitiveMonitor] Recovered ETS table after crash")
          reclaimed_table

        :not_found ->
          Mimo.EtsHeirManager.create_table(
            @table,
            [:named_table, :set, :public, read_concurrency: true],
            self()
          )
      end

    Logger.info("[MetacognitiveMonitor] Level 4 Self-Understanding initialized")
    schedule_cleanup()
    {:ok, %{table: table, decision_count: 0}}
  end

  @impl true
  def handle_cast({:record_decision, decision}, state) do
    # Store decision keyed by decision_id
    :ets.insert(@table, {decision.decision_id, decision, DateTime.utc_now()})

    # Also maintain an index by session_id for fast lookups
    session_key = {:session_index, decision.session_id}

    existing_decisions =
      case :ets.lookup(@table, session_key) do
        [{^session_key, list, _}] -> list
        [] -> []
      end

    :ets.insert(
      @table,
      {session_key, [decision.decision_id | existing_decisions], DateTime.utc_now()}
    )

    {:noreply, %{state | decision_count: state.decision_count + 1}}
  end

  @impl true
  def handle_call({:explain_session, session_id}, _from, state) do
    result =
      case get_session_decisions(session_id) do
        [] ->
          {:error, :not_found}

        decisions ->
          explanation = build_session_explanation(decisions)
          {:ok, explanation}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:explain_decision, decision_id}, _from, state) do
    result =
      case :ets.lookup(@table, decision_id) do
        [{^decision_id, decision, _}] ->
          explanation = build_decision_explanation(decision)
          {:ok, explanation}

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_trace, session_id}, _from, state) do
    result =
      case get_session_decisions(session_id) do
        [] -> {:error, :not_found}
        decisions -> {:ok, decisions}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:cognitive_load, _from, state) do
    load = calculate_cognitive_load()
    {:reply, {:ok, load}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_traces = :ets.info(@table, :size)

    # Count unique sessions
    session_count =
      :ets.foldl(
        fn
          {{:session_index, _}, _, _}, acc -> acc + 1
          _, acc -> acc
        end,
        0,
        @table
      )

    stats = %{
      total_decisions: state.decision_count,
      total_traces: total_traces,
      tracked_sessions: session_count,
      table: @table
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleaned = cleanup_expired()
    if cleaned > 0, do: Logger.debug("[MetacognitiveMonitor] Cleaned #{cleaned} expired traces")
    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_id(prefix) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}_#{random}"
  end

  defp extract_factors(context) do
    %{
      problem_complexity: context[:problem_complexity] || :unknown,
      involves_tools: context[:involves_tools] || false,
      similar_problems_found: context[:similar_problems_found] || 0,
      ambiguous: context[:ambiguous] || false,
      programming_task: context[:programming_task] || false
    }
  end

  defp get_session_decisions(session_id) do
    session_key = {:session_index, session_id}

    case :ets.lookup(@table, session_key) do
      [{^session_key, decision_ids, _}] ->
        decision_ids
        |> Enum.map(fn id ->
          case :ets.lookup(@table, id) do
            [{^id, decision, _}] -> decision
            [] -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.timestamp, DateTime)

      [] ->
        []
    end
  end

  defp build_session_explanation(decisions) do
    # Group by type
    by_type = Enum.group_by(decisions, & &1.decision_type)

    strategy_decision = by_type[:strategy_selection] |> List.first()

    %{
      session_id: (List.first(decisions) || %{})[:session_id],
      total_decisions: length(decisions),
      strategy: explain_strategy_choice(strategy_decision),
      step_evaluations: explain_step_evaluations(by_type[:step_evaluation] || []),
      branch_choices: explain_branch_choices(by_type[:branch_choice] || []),
      backtracks: explain_backtracks(by_type[:backtrack] || []),
      timeline: build_timeline(decisions),
      summary: build_summary(decisions)
    }
  end

  defp explain_strategy_choice(nil),
    do: %{selected: :unknown, reason: "No strategy decision recorded"}

  defp explain_strategy_choice(decision) do
    %{
      selected: decision.choice,
      reason: decision.reason,
      factors: decision.factors,
      alternatives_considered: decision.alternatives,
      decision_id: decision.decision_id,
      timestamp: decision.timestamp
    }
  end

  defp explain_step_evaluations([]), do: []

  defp explain_step_evaluations(evaluations) do
    Enum.map(evaluations, fn eval ->
      %{
        step_id: eval.context[:step_id],
        evaluation: eval.choice,
        confidence: eval.factors[:confidence],
        feedback: eval.reason,
        timestamp: eval.timestamp
      }
    end)
  end

  defp explain_branch_choices([]), do: []

  defp explain_branch_choices(branches) do
    Enum.map(branches, fn br ->
      %{
        branch_id: br.context[:branch_id],
        reason: br.reason,
        exploration_depth: br.factors[:exploration_depth],
        total_branches: br.factors[:total_branches],
        evaluation: br.factors[:branch_evaluation],
        timestamp: br.timestamp
      }
    end)
  end

  defp explain_backtracks([]), do: []

  defp explain_backtracks(backtracks) do
    Enum.map(backtracks, fn bt ->
      %{
        from_branch: bt.context[:from_branch_id],
        reason: bt.reason,
        branch_confidence: bt.factors[:branch_confidence],
        timestamp: bt.timestamp
      }
    end)
  end

  defp build_timeline(decisions) do
    Enum.map(decisions, fn d ->
      %{
        type: d.decision_type,
        choice: d.choice,
        timestamp: d.timestamp
      }
    end)
  end

  defp build_summary(decisions) do
    strategy_count = Enum.count(decisions, &(&1.decision_type == :strategy_selection))
    step_count = Enum.count(decisions, &(&1.decision_type == :step_evaluation))
    backtrack_count = Enum.count(decisions, &(&1.decision_type == :backtrack))

    "Session made #{length(decisions)} traced decisions: " <>
      "#{strategy_count} strategy selection, " <>
      "#{step_count} step evaluations, " <>
      "#{backtrack_count} backtracks"
  end

  defp build_decision_explanation(decision) do
    %{
      decision_id: decision.decision_id,
      session_id: decision.session_id,
      type: decision.decision_type,
      what: "Chose #{inspect(decision.choice)} from #{inspect(decision.alternatives)}",
      why: decision.reason,
      factors: decision.factors,
      context: decision.context,
      when: decision.timestamp
    }
  end

  defp calculate_cognitive_load do
    # Get active session count from ReasoningSession
    active_sessions = get_active_session_count()

    # Get recent error rate from FeedbackLoop
    error_rate = get_recent_error_rate()

    # Get backtrack frequency
    backtrack_rate = get_backtrack_rate()

    # Calculate load level
    level =
      cond do
        active_sessions >= @critical_load_sessions -> :critical
        active_sessions >= @high_load_sessions -> :high
        error_rate > @high_error_rate -> :high
        active_sessions > 5 or error_rate > 0.15 -> :normal
        true -> :low
      end

    # Build indicators
    indicators = build_load_indicators(active_sessions, error_rate, backtrack_rate)

    %{
      level: level,
      active_sessions: active_sessions,
      avg_session_duration_ms: get_avg_session_duration(),
      backtrack_rate: backtrack_rate,
      error_rate: error_rate,
      indicators: indicators
    }
  end

  defp get_active_session_count do
    # Query ReasoningSession for active count
    try do
      stats = Mimo.Cognitive.ReasoningSession.stats()
      stats[:active] || 0
    rescue
      _ -> 0
    end
  end

  defp get_recent_error_rate do
    # Query recent outcomes from FeedbackLoop
    try do
      case Mimo.Cognitive.FeedbackLoop.behavioral_metrics() do
        {:ok, metrics} ->
          success_rate = metrics[:session_activity][:success_rate] || 1.0
          1.0 - success_rate

        _ ->
          0.0
      end
    rescue
      _ -> 0.0
    end
  end

  defp get_backtrack_rate do
    # Calculate from our decision traces
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)

    recent_decisions =
      :ets.foldl(
        fn
          {id, decision, _}, acc when is_binary(id) ->
            if DateTime.compare(decision.timestamp, one_hour_ago) == :gt do
              [decision | acc]
            else
              acc
            end

          _, acc ->
            acc
        end,
        [],
        @table
      )

    total = length(recent_decisions)
    backtracks = Enum.count(recent_decisions, &(&1.decision_type == :backtrack))

    if total > 0, do: backtracks / total, else: 0.0
  end

  defp get_avg_session_duration do
    # Would need to track session durations - return 0 for now
    0.0
  end

  defp build_load_indicators(active_sessions, error_rate, backtrack_rate) do
    indicators = []

    indicators =
      if active_sessions >= @high_load_sessions do
        ["High concurrent reasoning sessions (#{active_sessions})" | indicators]
      else
        indicators
      end

    indicators =
      if error_rate > @high_error_rate do
        ["Elevated error rate (#{Float.round(error_rate * 100, 1)}%)" | indicators]
      else
        indicators
      end

    indicators =
      if backtrack_rate > 0.3 do
        ["Frequent backtracking (#{Float.round(backtrack_rate * 100, 1)}%)" | indicators]
      else
        indicators
      end

    if indicators == [], do: ["All metrics normal"], else: indicators
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -div(@ttl_ms, 1000), :second)

    # Find and delete expired entries
    expired =
      :ets.foldl(
        fn
          {key, _, timestamp}, acc when is_binary(key) ->
            if DateTime.compare(timestamp, cutoff) == :lt do
              [key | acc]
            else
              acc
            end

          _, acc ->
            acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end
end
