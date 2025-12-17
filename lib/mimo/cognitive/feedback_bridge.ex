defmodule Mimo.Cognitive.FeedbackBridge do
  @moduledoc """
  SPEC-087: Bridges FeedbackLoop outcomes to learning systems.

  This module closes the feedback loop by connecting:
  - FeedbackLoop.record_outcome → UsageFeedback.signal_useful/noise
  - FeedbackLoop.record_outcome → HebbianLearner (via telemetry)

  ## Architecture

  ```
  Tool Execution
       │
       ├─► OutcomeDetector.detect_*
       │        │
       └────────┼─► FeedbackLoop.record_outcome
                │        │
                │        └─► [:mimo, :feedback, :tool_execution] telemetry
                │                    │
                └────────────────────┴─► FeedbackBridge
                                              │
                                              ├─► UsageFeedback.signal_useful/noise
                                              └─► [:mimo, :learning, :outcome] telemetry
                                                       │
                                                       └─► HebbianLearner (future)
  ```

  ## Session Memory Tracking

  The bridge maintains a short-lived cache of memory IDs used per session.
  When an outcome is recorded, it looks up which memories were used
  and signals their usefulness/noise to UsageFeedback.
  """

  use GenServer
  require Logger

  alias Mimo.Brain.UsageFeedback

  # ETS table for tracking session → memory IDs
  @session_memories_table :mimo_session_memories

  # How long to keep session memory tracking (5 minutes)
  @session_ttl_ms 5 * 60 * 1000

  # Cleanup interval
  @cleanup_interval_ms 60_000

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track that memories were retrieved for a session.
  Call this when memory search returns results during tool execution.
  """
  @spec track_memories(String.t(), [integer()]) :: :ok
  def track_memories(session_id, memory_ids) when is_list(memory_ids) do
    GenServer.cast(__MODULE__, {:track_memories, session_id, memory_ids})
  end

  @doc """
  Get memories tracked for a session.
  """
  @spec get_session_memories(String.t()) :: [integer()]
  def get_session_memories(session_id) do
    case :ets.lookup(@session_memories_table, session_id) do
      [{^session_id, memory_ids, _timestamp}] -> memory_ids
      [] -> []
    end
  catch
    :error, :badarg -> []
  end

  @doc """
  Get bridge statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for session memory tracking
    :ets.new(@session_memories_table, [:named_table, :public, :set])

    # Attach to FeedbackLoop telemetry events
    :telemetry.attach(
      "feedback-bridge-tool-execution",
      [:mimo, :feedback, :tool_execution],
      &__MODULE__.handle_tool_execution_feedback/4,
      nil
    )

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      outcomes_processed: 0,
      useful_signaled: 0,
      noise_signaled: 0,
      sessions_tracked: 0
    }

    Logger.info("[FeedbackBridge] SPEC-087 initialized - learning feedback enabled")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track_memories, session_id, memory_ids}, state) do
    timestamp = System.system_time(:millisecond)

    # Merge with existing memories for this session
    existing =
      case :ets.lookup(@session_memories_table, session_id) do
        [{^session_id, ids, _}] -> ids
        [] -> []
      end

    merged = Enum.uniq(existing ++ memory_ids)
    :ets.insert(@session_memories_table, {session_id, merged, timestamp})

    {:noreply, %{state | sessions_tracked: state.sessions_tracked + 1}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    session_count =
      try do
        :ets.info(@session_memories_table, :size) || 0
      catch
        :error, :badarg -> 0
      end

    {:reply, Map.put(state, :active_sessions, session_count), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ==========================================================================
  # Telemetry Handlers
  # ==========================================================================

  @doc false
  def handle_tool_execution_feedback(_event, measurements, metadata, _config) do
    # Extract relevant data
    success = Map.get(metadata, :success, false)
    context = Map.get(metadata, :context, %{})

    # Try to find session ID from context
    session_id = extract_session_id(context)

    if session_id do
      # Get memories that were used in this session
      memory_ids = get_session_memories(session_id)

      if memory_ids != [] do
        # Signal to UsageFeedback based on outcome
        if success do
          UsageFeedback.signal_useful(session_id, memory_ids)
        else
          UsageFeedback.signal_noise(session_id, memory_ids)
        end

        # Emit learning telemetry for other systems
        :telemetry.execute(
          [:mimo, :learning, :outcome],
          %{memory_count: length(memory_ids)},
          %{
            session_id: session_id,
            success: success,
            memory_ids: memory_ids,
            latency_ms: Map.get(measurements, :latency_ms, 0)
          }
        )
      end
    end
  rescue
    e ->
      Logger.warning("[FeedbackBridge] Error processing feedback: #{inspect(e)}")
      :ok
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp extract_session_id(context) do
    # Try various context fields that might contain session ID
    context[:session_id] ||
      context["session_id"] ||
      context[:thread_id] ||
      context["thread_id"] ||
      context[:request_id] ||
      context["request_id"]
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_old_sessions do
    now = System.system_time(:millisecond)
    cutoff = now - @session_ttl_ms

    # Find and delete old entries
    :ets.foldl(
      fn {session_id, _memory_ids, timestamp}, acc ->
        if timestamp < cutoff do
          :ets.delete(@session_memories_table, session_id)
        end

        acc
      end,
      :ok,
      @session_memories_table
    )
  rescue
    _ -> :ok
  end
end
