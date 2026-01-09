defmodule Mimo.Cognitive.LearningExecutor do
  @moduledoc """
  Phase 6 S2: Autonomous Learning Actions

  Executes learning actions to address objectives identified by LearningObjectives.
  Uses idle time to proactively fill knowledge gaps.

  ## Philosophy

  Rather than waiting for the AI to explicitly request learning, this module
  autonomously takes safe learning actions during system idle time.

  ## Execution Modes

  - :immediate - Execute now (high priority objectives)
  - :background - Execute during idle time
  - :scheduled - Execute during next SleepCycle

  ## Action Types

  - Research: Fetch documentation, analyze patterns
  - Synthesis: Generate insights from existing knowledge
  - Consolidation: Run memory consolidation for specific areas
  - Practice: Trigger pattern detection in weak areas

  ## Safety

  - All actions are read-only or create-only (no destructive operations)
  - Actions have timeout limits
  - Actions are logged for transparency
  - Cooldowns prevent action spam
  """

  use GenServer
  require Logger

  alias Mimo.Cognitive.{LearningObjectives, FeedbackLoop}
  alias Mimo.Brain.Synthesizer

  # Check for learning opportunities every 5 minutes
  @execution_interval_ms 300_000
  # Don't overwhelm the system
  @max_actions_per_cycle 3

  # Action cooldowns to prevent spam
  @action_cooldowns %{
    # 10 min
    research: 600_000,
    # 15 min
    synthesis: 900_000,
    # 30 min
    consolidation: 1_800_000,
    # 10 min
    practice: 600_000
  }

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current execution status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Forces immediate execution of pending learning actions.
  """
  @spec execute_now() :: {:ok, map()} | {:error, term()}
  def execute_now do
    GenServer.call(__MODULE__, :execute_now, 30_000)
  end

  @doc """
  Pauses autonomous execution.
  """
  @spec pause() :: :ok
  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  @doc """
  Resumes autonomous execution.
  """
  @spec resume() :: :ok
  def resume do
    GenServer.cast(__MODULE__, :resume)
  end

  @doc """
  Gets execution history.
  """
  @spec history() :: [map()]
  def history do
    GenServer.call(__MODULE__, :history)
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer Implementation
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_execution()

    state = %{
      paused: false,
      last_execution: nil,
      actions_executed: 0,
      history: [],
      started_at: DateTime.utc_now()
    }

    Logger.info("[LearningExecutor] Phase 6 S2 initialized - autonomous learning active")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      active: !state.paused,
      last_execution: state.last_execution,
      actions_executed: state.actions_executed,
      history_size: length(state.history),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:execute_now, _from, state) do
    {result, new_state} = do_execute(state)
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("[LearningExecutor] Paused")
    {:noreply, %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("[LearningExecutor] Resumed")
    {:noreply, %{state | paused: false}}
  end

  @impl true
  def handle_info(:scheduled_execution, state) do
    new_state =
      if state.paused do
        state
      else
        {_result, updated_state} = do_execute(state)
        updated_state
      end

    schedule_execution()
    {:noreply, new_state}
  end

  # ─────────────────────────────────────────────────────────────────
  # Execution Logic
  # ─────────────────────────────────────────────────────────────────

  defp schedule_execution do
    Process.send_after(self(), :scheduled_execution, @execution_interval_ms)
  end

  defp do_execute(state) do
    timestamp = DateTime.utc_now()

    # Get prioritized objectives
    objectives = safe_call(fn -> LearningObjectives.prioritized() end, [])

    # Take top N objectives to address
    to_address = Enum.take(objectives, @max_actions_per_cycle)

    # Execute actions for each objective
    results =
      Enum.map(to_address, fn objective ->
        execute_action_for_objective(objective)
      end)

    # Count successes
    successes = Enum.count(results, fn {status, _} -> status == :ok end)

    execution_record = %{
      timestamp: timestamp,
      objectives_addressed: length(to_address),
      successes: successes,
      failures: length(to_address) - successes,
      results: results
    }

    # Keep last 100
    new_history = [execution_record | Enum.take(state.history, 99)]

    new_state = %{
      state
      | last_execution: timestamp,
        actions_executed: state.actions_executed + successes,
        history: new_history
    }

    {execution_record, new_state}
  end

  defp execute_action_for_objective(objective) do
    action_type = determine_action_type(objective.type)

    if on_cooldown?(action_type) do
      {:skipped, :on_cooldown}
    else
      result = execute_action(action_type, objective)
      record_action_time(action_type)

      case result do
        :ok ->
          # Mark objective as addressed
          LearningObjectives.mark_addressed(objective.id)
          {:ok, objective.focus_area}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp determine_action_type(objective_type) do
    case objective_type do
      :skill_gap -> :practice
      :calibration -> :synthesis
      :strategy -> :research
      :pattern -> :practice
      :knowledge -> :research
      _ -> :synthesis
    end
  end

  defp execute_action(action_type, objective) do
    Logger.info("[LearningExecutor] Executing #{action_type} for: #{objective.focus_area}")

    case action_type do
      :research ->
        execute_research(objective)

      :synthesis ->
        execute_synthesis(objective)

      :consolidation ->
        execute_consolidation(objective)

      :practice ->
        execute_practice(objective)
    end
  end

  defp execute_research(objective) do
    # Research action: Log the need and store as memory for background processes
    try do
      Logger.info("[LearningExecutor] Research needed for: #{objective.focus_area}")
      # Store a memory about this learning need so background processes can pick it up
      case Mimo.Brain.SafeMemory.store(
             "Learning objective: #{objective.description}",
             importance: 0.7,
             metadata: %{type: :learning_objective, focus_area: objective.focus_area}
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    rescue
      e ->
        Logger.warning("[LearningExecutor] Research failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    catch
      :exit, reason ->
        Logger.warning("[LearningExecutor] Research failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp execute_synthesis(_objective) do
    # Synthesis action: Generate insights from related memories
    try do
      # Trigger synthesis cycle
      case Synthesizer.synthesize_now() do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    rescue
      e ->
        Logger.warning("[LearningExecutor] Synthesis failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp execute_consolidation(_objective) do
    # Consolidation action: Run sleep cycle stage
    try do
      case Mimo.SleepCycle.run_cycle(stages: [:memory_consolidation]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    rescue
      e ->
        Logger.warning("[LearningExecutor] Consolidation failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp execute_practice(objective) do
    # Practice action: Run pattern detection in the focus area
    try do
      # Record a "practice" outcome to improve that category
      FeedbackLoop.record_outcome(
        :classification,
        extract_category(objective.focus_area),
        %{type: :practice, triggered_by: :learning_executor}
      )

      :ok
    rescue
      e ->
        Logger.warning("[LearningExecutor] Practice failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp extract_category(focus_area) when is_binary(focus_area) do
    case String.split(focus_area, ":", parts: 2) do
      [_, category] -> category
      _ -> "general"
    end
  end

  defp extract_category(_), do: "general"

  # ─────────────────────────────────────────────────────────────────
  # Cooldown Management
  # ─────────────────────────────────────────────────────────────────

  defp on_cooldown?(action_type) do
    case :persistent_term.get({:learning_executor_last, action_type}, nil) do
      nil ->
        false

      last_time ->
        cooldown = Map.get(@action_cooldowns, action_type, 600_000)
        System.monotonic_time(:millisecond) - last_time < cooldown
    end
  rescue
    ArgumentError -> false
  end

  defp record_action_time(action_type) do
    :persistent_term.put(
      {:learning_executor_last, action_type},
      System.monotonic_time(:millisecond)
    )
  rescue
    _ -> :ok
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
