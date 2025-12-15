defmodule Mimo.Brain.CognitiveLifecycle do
  @moduledoc """
  Tracks and analyzes the cognitive lifecycle of AI agent interactions.

  The Cognitive Lifecycle Pattern (SPEC-042) defines four phases:
  1. CONTEXT (15-20%) - Gathering relevant memories, knowledge, context
  2. DELIBERATE (15-20%) - Reasoning, planning, assessing options
  3. ACTION (45-55%) - Executing tools, making changes
  4. LEARN (10-15%) - Storing insights, updating knowledge

  This module:
  - Classifies each tool call into a lifecycle phase
  - Tracks phase transitions per thread
  - Detects anti-patterns (e.g., jumping to action without context)
  - Provides metrics for workflow optimization

  ## Integration

  Called from ThreadManager.record_interaction to classify and track
  each tool invocation automatically.

  ## Anti-Pattern Detection

  - `action_without_context`: Jumping directly to file/terminal without
    first consulting memory or knowledge
  - `no_learning`: Completing actions without storing insights
  - `imbalanced_phases`: Phase distribution outside target ranges

  ## Example

      # Classify a tool call
      CognitiveLifecycle.classify_tool("memory", "search")
      # => :context

      # Track a transition
      CognitiveLifecycle.track_transition(thread_id, "file", "read")
      # => {:ok, %{phase: :action, warning: "Action without context phase"}}

      # Get phase distribution
      CognitiveLifecycle.get_phase_distribution(thread_id)
      # => %{context: 3, deliberate: 2, action: 5, learn: 1}
  """

  use GenServer
  require Logger

  # Target phase distribution ranges from SPEC-042
  @target_ranges %{
    context: {0.15, 0.20},
    deliberate: {0.15, 0.20},
    action: {0.45, 0.55},
    learn: {0.10, 0.15}
  }

  # Phase classifications by tool and operation
  @phase_classifications %{
    # CONTEXT phase tools - gathering information
    context: %{
      "ask_mimo" => :all,
      "memory" => ["search", "list", "stats", "decay_check"],
      "knowledge" => ["query", "traverse", "explore", "node", "path", "stats", "neighborhood"],
      "prepare_context" => :all,
      "onboard" => :all,
      "analyze_file" => :all,
      "debug_error" => :all,
      "suggest_next_tool" => :all,
      # Composite tool alias
      "meta" => ["prepare_context", "analyze_file", "debug_error", "suggest_next_tool"]
    },
    # DELIBERATE phase tools - reasoning and planning
    deliberate: %{
      "reason" => :all,
      "think" => :all,
      "cognitive" => ["assess", "gaps", "can_answer", "query"],
      "reflector" => :all,
      "code" => [
        "definition",
        "references",
        "symbols",
        "call_graph",
        "search",
        "index",
        "diagnose",
        "check",
        "lint",
        "typecheck",
        "diagnostics_all",
        "library_get",
        "library_search",
        "library_ensure",
        "library_discover",
        "library_stats"
      ],
      # Deprecated aliases that map to code
      "code_symbols" => :all,
      "diagnostics" => :all,
      "library" => :all,
      # Emergence for pattern analysis
      "emergence" => [
        "dashboard",
        "detect",
        "alerts",
        "search",
        "suggest",
        "list",
        "status",
        "pattern"
      ]
    },
    # ACTION phase tools - executing changes
    action: %{
      "file" => [
        "read",
        "write",
        "edit",
        "delete_lines",
        "replace_lines",
        "insert_after",
        "insert_before",
        "replace_string",
        "move",
        "create_directory",
        "read_multiple",
        "glob",
        "multi_replace"
      ],
      "terminal" => :all,
      "web" => :all,
      # Deprecated web aliases
      "fetch" => :all,
      "search" => :all,
      "blink" => :all,
      "browser" => :all,
      "vision" => :all,
      "sonar" => :all,
      "web_extract" => :all,
      "web_parse" => :all,
      # Procedures
      "run_procedure" => :all,
      # File inspection (lower-impact action)
      "file_search" => :all,
      "file_ls" => :all,
      "file_list_directory" => :all,
      "file_get_info" => :all,
      "file_diff" => :all,
      "file_list_symbols" => :all,
      "file_read_symbol" => :all,
      "file_search_symbols" => :all
    },
    # LEARN phase tools - storing insights
    learn: %{
      "memory" => ["store"],
      "knowledge" => ["teach", "link", "link_memory", "sync_dependencies"],
      "store_fact" => :all,
      "ingest" => :all,
      "emergence" => ["amplify", "promote", "cycle"]
    }
  }

  # State structure for tracking thread lifecycle
  defmodule ThreadState do
    @moduledoc false
    defstruct [
      :thread_id,
      :current_phase,
      :phase_history,
      :phase_counts,
      :warnings,
      :last_activity,
      :session_start
    ]

    @type t :: %__MODULE__{
            thread_id: String.t(),
            current_phase: atom() | nil,
            phase_history: [{atom(), DateTime.t()}],
            phase_counts: %{atom() => non_neg_integer()},
            warnings: [map()],
            last_activity: DateTime.t(),
            session_start: DateTime.t()
          }

    def new(thread_id) do
      now = DateTime.utc_now()

      %__MODULE__{
        thread_id: thread_id,
        current_phase: nil,
        phase_history: [],
        phase_counts: %{context: 0, deliberate: 0, action: 0, learn: 0},
        warnings: [],
        last_activity: now,
        session_start: now
      }
    end
  end

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Classifies a tool call into a cognitive lifecycle phase.

  ## Examples

      iex> CognitiveLifecycle.classify_tool("memory", "search")
      :context

      iex> CognitiveLifecycle.classify_tool("file", "edit")
      :action

      iex> CognitiveLifecycle.classify_tool("reason", "guided")
      :deliberate
  """
  @spec classify_tool(String.t(), String.t() | nil) :: atom()
  def classify_tool(tool_name, operation \\ nil)

  def classify_tool(tool_name, operation) when is_binary(tool_name) do
    # Normalize tool name
    tool = String.downcase(tool_name) |> String.trim()
    op = if operation, do: String.downcase(to_string(operation)) |> String.trim(), else: nil

    find_phase(tool, op)
  end

  def classify_tool(_, _), do: :unknown

  @doc """
  Tracks a phase transition for a thread.

  Returns the new phase and any warnings detected.
  """
  @spec track_transition(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{phase: atom(), warnings: [map()]}} | {:error, term()}
  def track_transition(thread_id, tool_name, operation \\ nil) do
    GenServer.call(__MODULE__, {:track_transition, thread_id, tool_name, operation})
  end

  @doc """
  Gets the phase distribution for a thread.

  Returns counts and percentages for each phase.
  """
  @spec get_phase_distribution(String.t()) :: map()
  def get_phase_distribution(thread_id) do
    GenServer.call(__MODULE__, {:get_distribution, thread_id})
  end

  @doc """
  Checks for anti-patterns in a thread's workflow.
  """
  @spec check_anti_patterns(String.t()) :: [map()]
  def check_anti_patterns(thread_id) do
    GenServer.call(__MODULE__, {:check_anti_patterns, thread_id})
  end

  @doc """
  Gets aggregate statistics across all tracked threads.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Gets detailed state for a specific thread.
  """
  @spec get_thread_state(String.t()) :: ThreadState.t() | nil
  def get_thread_state(thread_id) do
    GenServer.call(__MODULE__, {:get_thread_state, thread_id})
  end

  @doc """
  Clears state for a thread (e.g., when thread ends).
  """
  @spec clear_thread(String.t()) :: :ok
  def clear_thread(thread_id) do
    GenServer.cast(__MODULE__, {:clear_thread, thread_id})
  end

  @doc """
  Returns the target phase distribution ranges.
  """
  @spec target_ranges() :: map()
  def target_ranges, do: @target_ranges

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # ETS table for thread states
    Mimo.EtsSafe.ensure_table(:cognitive_lifecycle_threads, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    Logger.info("[CognitiveLifecycle] Started")
    {:ok, %{started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call({:track_transition, thread_id, tool_name, operation}, _from, state) do
    phase = classify_tool(tool_name, operation)
    thread_state = get_or_create_thread_state(thread_id)
    now = DateTime.utc_now()

    # Detect anti-patterns
    new_warnings = detect_transition_warnings(thread_state, phase)

    # Update thread state
    updated_state = %{
      thread_state
      | current_phase: phase,
        phase_history: [{phase, now} | Enum.take(thread_state.phase_history, 99)],
        phase_counts: Map.update!(thread_state.phase_counts, phase, &(&1 + 1)),
        warnings: new_warnings ++ Enum.take(thread_state.warnings, 49),
        last_activity: now
    }

    :ets.insert(:cognitive_lifecycle_threads, {thread_id, updated_state})

    # Log if warnings detected
    if new_warnings != [] do
      warning_msgs = Enum.map_join(new_warnings, ", ", & &1.message)
      Logger.debug("[CognitiveLifecycle] Thread #{thread_id}: #{warning_msgs}")
    end

    {:reply, {:ok, %{phase: phase, warnings: new_warnings}}, state}
  end

  @impl true
  def handle_call({:get_distribution, thread_id}, _from, state) do
    thread_state = get_or_create_thread_state(thread_id)
    total = Enum.sum(Map.values(thread_state.phase_counts))

    distribution =
      if total > 0 do
        %{
          counts: thread_state.phase_counts,
          percentages:
            Map.new(thread_state.phase_counts, fn {phase, count} ->
              {phase, Float.round(count / total * 100, 1)}
            end),
          total: total,
          target_ranges: @target_ranges,
          health: calculate_health(thread_state.phase_counts, total)
        }
      else
        %{
          counts: thread_state.phase_counts,
          percentages: %{context: 0.0, deliberate: 0.0, action: 0.0, learn: 0.0},
          total: 0,
          target_ranges: @target_ranges,
          health: :insufficient_data
        }
      end

    {:reply, distribution, state}
  end

  @impl true
  def handle_call({:check_anti_patterns, thread_id}, _from, state) do
    thread_state = get_or_create_thread_state(thread_id)
    {:reply, thread_state.warnings, state}
  end

  @impl true
  def handle_call({:get_thread_state, thread_id}, _from, state) do
    result =
      case :ets.lookup(:cognitive_lifecycle_threads, thread_id) do
        [{^thread_id, thread_state}] -> thread_state
        [] -> nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all_threads = :ets.tab2list(:cognitive_lifecycle_threads)

    aggregate =
      Enum.reduce(
        all_threads,
        %{
          total_threads: 0,
          total_interactions: 0,
          phase_counts: %{context: 0, deliberate: 0, action: 0, learn: 0},
          warning_counts: %{action_without_context: 0, no_learning: 0, imbalanced_phases: 0},
          active_threads: 0
        },
        fn {_id, thread_state}, acc ->
          # 5 min
          cutoff = DateTime.add(DateTime.utc_now(), -300, :second)
          is_active = DateTime.compare(thread_state.last_activity, cutoff) == :gt

          %{
            acc
            | total_threads: acc.total_threads + 1,
              total_interactions:
                acc.total_interactions + Enum.sum(Map.values(thread_state.phase_counts)),
              phase_counts:
                Map.merge(acc.phase_counts, thread_state.phase_counts, fn _, a, b -> a + b end),
              warning_counts: count_warnings(acc.warning_counts, thread_state.warnings),
              active_threads: acc.active_threads + if(is_active, do: 1, else: 0)
          }
        end
      )

    total = Enum.sum(Map.values(aggregate.phase_counts))

    percentages =
      if total > 0 do
        Map.new(aggregate.phase_counts, fn {phase, count} ->
          {phase, Float.round(count / total * 100, 1)}
        end)
      else
        %{context: 0.0, deliberate: 0.0, action: 0.0, learn: 0.0}
      end

    stats = %{
      started_at: state.started_at,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at),
      total_threads: aggregate.total_threads,
      active_threads: aggregate.active_threads,
      total_interactions: aggregate.total_interactions,
      phase_distribution: %{
        counts: aggregate.phase_counts,
        percentages: percentages,
        target_ranges: @target_ranges
      },
      warning_summary: aggregate.warning_counts,
      health: calculate_health(aggregate.phase_counts, total)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:clear_thread, thread_id}, state) do
    :ets.delete(:cognitive_lifecycle_threads, thread_id)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_phase(tool, operation) do
    Enum.find_value(@phase_classifications, :unknown, fn {phase, tools} ->
      case Map.get(tools, tool) do
        nil ->
          nil

        :all ->
          phase

        operations when is_list(operations) ->
          if operation in operations, do: phase, else: nil
      end
    end)
  end

  defp get_or_create_thread_state(thread_id) do
    case :ets.lookup(:cognitive_lifecycle_threads, thread_id) do
      [{^thread_id, state}] ->
        state

      [] ->
        new_state = ThreadState.new(thread_id)
        :ets.insert(:cognitive_lifecycle_threads, {thread_id, new_state})
        new_state
    end
  end

  defp detect_transition_warnings(thread_state, new_phase) do
    warnings = []

    # Anti-pattern: Jumping to action without context
    warnings =
      if new_phase == :action and
           thread_state.current_phase == nil and
           thread_state.phase_counts.context == 0 do
        [
          %{
            type: :action_without_context,
            message: "Jumped to action phase without gathering context first",
            timestamp: DateTime.utc_now(),
            severity: :warning
          }
          | warnings
        ]
      else
        warnings
      end

    # Anti-pattern: Extended action without learning
    warnings =
      if new_phase == :action and
           thread_state.phase_counts.action > 5 and
           thread_state.phase_counts.learn == 0 do
        [
          %{
            type: :no_learning,
            message: "Multiple actions without any learning/storage phase",
            timestamp: DateTime.utc_now(),
            severity: :info
          }
          | warnings
        ]
      else
        warnings
      end

    warnings
  end

  defp calculate_health(_phase_counts, total) when total < 5, do: :insufficient_data

  defp calculate_health(phase_counts, total) do
    issues =
      Enum.reduce(@target_ranges, [], fn {phase, {min, max}}, acc ->
        actual = Map.get(phase_counts, phase, 0) / total

        cond do
          actual < min * 0.5 -> [{:severely_low, phase} | acc]
          actual < min -> [{:low, phase} | acc]
          actual > max * 1.5 -> [{:severely_high, phase} | acc]
          actual > max -> [{:high, phase} | acc]
          true -> acc
        end
      end)

    case issues do
      [] -> :healthy
      issues when length(issues) == 1 -> :minor_imbalance
      issues when length(issues) <= 2 -> :moderate_imbalance
      _ -> :significant_imbalance
    end
  end

  defp count_warnings(acc, warnings) do
    Enum.reduce(warnings, acc, fn warning, acc ->
      Map.update(acc, warning.type, 1, &(&1 + 1))
    end)
  end
end
