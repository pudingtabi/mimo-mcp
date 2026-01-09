defmodule Mimo.Awakening.SessionTracker do
  @moduledoc """
  SPEC-040: Session Tracking for Awakening Protocol

  Tracks the lifecycle of MCP sessions, triggering awakening on first tool call.
  Uses ETS for fast session state lookup and GenServer for state management.

  ## Session Lifecycle

  1. Session starts on MCP `initialize` → `start_session/1`
  2. First tool call triggers awakening → `trigger_awakening/1`
  3. Subsequent tool calls increment counters
  4. Session ends on MCP disconnect or timeout

  ## State Structure

  Each session tracks:
  - session_id: Unique identifier
  - started_at: When session began
  - awakened_at: When first tool call occurred (triggers awakening)
  - power_level: Current power level at session start
  - xp_at_start: XP when session started
  - tool_calls_this_session: Counter
  - memories_stored_this_session: Counter
  - is_first_session: Boolean for new users
  - awakening_sent: Whether awakening context was injected
  """
  use GenServer
  require Logger

  alias Mimo.Awakening.Stats

  @ets_table :mimo_awakening_sessions
  # Sessions timeout after 4 hours of inactivity
  @session_timeout :timer.hours(4)

  # Session state structure
  defstruct [
    :session_id,
    :started_at,
    :awakened_at,
    :power_level,
    :xp_at_start,
    :user_id,
    :project_id,
    :last_memory_search_at,
    :last_context_tool_at,
    tool_calls_this_session: 0,
    memories_stored_this_session: 0,
    is_first_session: false,
    awakening_sent: false,
    # SPEC-040 v1.2: Tool balance tracking for behavioral transformation
    # Context-first tools: memory, ask_mimo, knowledge, prepare_context, code_symbols, library, diagnostics
    # Action tools: file, terminal
    context_tool_calls: 0,
    action_tool_calls: 0,
    # Track consecutive action calls without context
    consecutive_action_without_context: 0
  ]

  @type t :: %__MODULE__{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new session. Called on MCP initialize.

  ## Options (keyword list)

  - `:user_id` - Optional user identifier
  - `:project_id` - Optional project identifier
  - `:session_id` - Optional external session ID (if not provided, one is generated)

  ## Returns

  `{:ok, session_state}` with the new session state
  """
  @spec start_session(keyword()) :: {:ok, t()}
  def start_session(opts \\ []) do
    GenServer.call(__MODULE__, {:start_session, opts})
  end

  @doc """
  Get current session state for a session ID.
  """
  @spec get_session(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_session(session_id) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get the current active session for this process.
  Uses process dictionary for fast lookup.
  """
  @spec get_current_session() :: {:ok, t()} | {:error, :no_session}
  def get_current_session do
    case Process.get(:mimo_session_id) do
      nil -> {:error, :no_session}
      session_id -> get_session(session_id)
    end
  end

  @doc """
  Trigger awakening for a session (called on first tool call).
  Returns the awakening context if this is the first call, nil otherwise.

  Updates session state atomically.
  """
  @spec trigger_awakening(String.t()) ::
          {:ok, t(), :awakened | :already_awakened} | {:error, :not_found}
  def trigger_awakening(session_id) do
    GenServer.call(__MODULE__, {:trigger_awakening, session_id})
  end

  @doc """
  Record a tool call for the session with tool classification.
  Context tools: memory, ask_mimo, knowledge, prepare_context, code_symbols, library, diagnostics, cognitive, reason
  Action tools: file, terminal
  """
  @spec record_tool_call(String.t(), String.t()) :: :ok
  def record_tool_call(session_id, tool_name \\ "unknown") do
    GenServer.cast(__MODULE__, {:record_tool_call, session_id, tool_name})
  end

  @doc """
  Record a memory stored for the session.
  """
  @spec record_memory_stored(String.t()) :: :ok
  def record_memory_stored(session_id) do
    GenServer.cast(__MODULE__, {:record_memory_stored, session_id})
  end

  @doc """
  End a session explicitly.
  """
  @spec end_session(String.t()) :: :ok
  def end_session(session_id) do
    GenServer.cast(__MODULE__, {:end_session, session_id})
  end

  @doc """
  List all active sessions.
  """
  @spec list_sessions() :: [t()]
  def list_sessions do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, state} -> state end)
  end

  @doc """
  Get session statistics.
  """
  @spec session_stats() :: map()
  def session_stats do
    sessions = list_sessions()

    %{
      active_sessions: length(sessions),
      total_tool_calls: Enum.sum(Enum.map(sessions, & &1.tool_calls_this_session)),
      total_memories_stored: Enum.sum(Enum.map(sessions, & &1.memories_stored_this_session)),
      awakened_sessions: Enum.count(sessions, & &1.awakening_sent)
    }
  end

  @impl true
  def init(_opts) do
    # Create ETS table for fast session lookup
    Mimo.EtsSafe.ensure_table(@ets_table, [:named_table, :public, :set, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_session, opts}, _from, state) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    external_session_id = Keyword.get(opts, :session_id)

    # Use external session ID if provided, otherwise generate one
    session_id = external_session_id || generate_session_id()

    # Load or create stats
    {:ok, stats} = Stats.get_or_create(user_id, project_id)

    # Check if this is a quick reconnect (within 5 minutes) to suppress duplicate awakening
    is_reconnect =
      stats.last_session &&
        DateTime.diff(DateTime.utc_now(), stats.last_session, :minute) < 5

    session_state = %__MODULE__{
      session_id: session_id,
      started_at: DateTime.utc_now(),
      power_level: stats.current_level,
      xp_at_start: stats.total_xp,
      user_id: user_id,
      project_id: project_id,
      is_first_session: stats.total_sessions == 0,
      awakening_sent: is_reconnect
    }

    # Store in ETS
    :ets.insert(@ets_table, {session_id, session_state})

    Logger.debug("Awakening: Started session #{session_id} (power level #{stats.current_level})")

    {:reply, {:ok, session_state}, state}
  end

  @impl true
  def handle_call({:trigger_awakening, session_id}, _from, state) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, session_state}] ->
        if session_state.awakening_sent do
          {:reply, {:ok, session_state, :already_awakened}, state}
        else
          # Mark as awakened
          updated_state = %{session_state | awakening_sent: true, awakened_at: DateTime.utc_now()}

          :ets.insert(@ets_table, {session_id, updated_state})

          Logger.info(
            "Awakening: Session #{session_id} awakened at power level #{updated_state.power_level}"
          )

          {:reply, {:ok, updated_state, :awakened}, state}
        end

      [] ->
        # Session not found, create a minimal one
        session_state = %__MODULE__{
          session_id: session_id,
          started_at: DateTime.utc_now(),
          awakened_at: DateTime.utc_now(),
          power_level: 1,
          xp_at_start: 0,
          awakening_sent: true
        }

        :ets.insert(@ets_table, {session_id, session_state})

        {:reply, {:ok, session_state, :awakened}, state}
    end
  end

  @impl true
  def handle_cast({:record_tool_call, session_id, tool_name}, state) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, session_state}] ->
        tool_type = classify_tool(tool_name)
        now = DateTime.utc_now()

        updated =
          case tool_type do
            :context ->
              %{
                session_state
                | tool_calls_this_session: session_state.tool_calls_this_session + 1,
                  context_tool_calls: session_state.context_tool_calls + 1,
                  consecutive_action_without_context: 0,
                  last_context_tool_at: now,
                  last_memory_search_at:
                    if(tool_name in ["memory", "ask_mimo"],
                      do: now,
                      else: session_state.last_memory_search_at
                    )
              }

            :action ->
              %{
                session_state
                | tool_calls_this_session: session_state.tool_calls_this_session + 1,
                  action_tool_calls: session_state.action_tool_calls + 1,
                  consecutive_action_without_context:
                    session_state.consecutive_action_without_context + 1
              }

            :other ->
              %{session_state | tool_calls_this_session: session_state.tool_calls_this_session + 1}
          end

        :ets.insert(@ets_table, {session_id, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  # Backward compatible: handle old 2-arg version
  @impl true
  def handle_cast({:record_tool_call, session_id}, state) do
    handle_cast({:record_tool_call, session_id, "unknown"}, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_memory_stored, session_id}, state) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, session_state}] ->
        updated = %{
          session_state
          | memories_stored_this_session: session_state.memories_stored_this_session + 1
        }

        :ets.insert(@ets_table, {session_id, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:end_session, session_id}, state) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, session_state}] ->
        # Increment session count in stats
        Stats.increment_sessions(session_state.user_id, session_state.project_id)

        # Remove from ETS
        :ets.delete(@ets_table, session_id)

        Logger.debug(
          "Awakening: Ended session #{session_id} (#{session_state.tool_calls_this_session} tool calls)"
        )

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    cleanup_stale_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  defp generate_session_id do
    UUID.uuid4()
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_sessions, :timer.minutes(15))
  end

  defp cleanup_stale_sessions do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@session_timeout, :millisecond)

    stale_sessions =
      :ets.tab2list(@ets_table)
      |> Enum.filter(fn {_id, state} ->
        DateTime.compare(state.started_at, cutoff) == :lt
      end)

    Enum.each(stale_sessions, fn {session_id, session_state} ->
      # Increment session count before removing
      Stats.increment_sessions(session_state.user_id, session_state.project_id)
      :ets.delete(@ets_table, session_id)
      Logger.debug("Awakening: Cleaned up stale session #{session_id}")
    end)

    unless Enum.empty?(stale_sessions) do
      Logger.info("Awakening: Cleaned up #{length(stale_sessions)} stale sessions")
    end
  end

  @context_tools ~w(memory ask_mimo knowledge prepare_context code_symbols library diagnostics cognitive reason graph onboard analyze_file debug_error awakening_status)
  @action_tools ~w(file terminal)

  defp classify_tool(tool_name) when tool_name in @context_tools, do: :context
  defp classify_tool(tool_name) when tool_name in @action_tools, do: :action
  defp classify_tool(_), do: :other

  @doc """
  Get tool balance metrics for the current session.
  Returns a map with context/action ratio and behavioral suggestions.
  """
  @spec get_tool_balance(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tool_balance(session_id) do
    case get_session(session_id) do
      {:ok, session} ->
        total = session.context_tool_calls + session.action_tool_calls
        ratio = if total > 0, do: session.context_tool_calls / total, else: 0.0

        suggestion =
          cond do
            session.consecutive_action_without_context >= 5 ->
              "⚠️ #{session.consecutive_action_without_context} consecutive action tools without context! Use `memory search` or `ask_mimo` first."

            ratio < 0.2 and total >= 5 ->
              "Low context usage (#{Float.round(ratio * 100, 1)}%). Try `memory search` before file reads."

            ratio >= 0.3 ->
              "✅ Good tool balance (#{Float.round(ratio * 100, 1)}% context-first)."

            true ->
              nil
          end

        {:ok,
         %{
           context_tool_calls: session.context_tool_calls,
           action_tool_calls: session.action_tool_calls,
           total_calls: total,
           context_ratio: Float.round(ratio, 3),
           consecutive_action_without_context: session.consecutive_action_without_context,
           last_memory_search_at: session.last_memory_search_at,
           suggestion: suggestion
         }}

      {:error, _} = error ->
        error
    end
  end
end
