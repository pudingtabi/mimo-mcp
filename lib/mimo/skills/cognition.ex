defmodule Mimo.Skills.Cognition do
  @moduledoc """
  Cognitive functions for LLM reasoning.

  Provides:
  - Think: Record individual thoughts
  - Plan: Record multi-step plans
  - Sequential Thinking: Dynamic problem-solving through structured thought sequences

  Native replacement for sequential_thinking MCP server.
  """
  require Logger
  use Agent

  # ==========================================================================
  # State Management for Sequential Thinking
  # ==========================================================================

  defmodule ThinkingState do
    @moduledoc false
    defstruct sessions: %{}, current_session: nil
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %ThinkingState{} end, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  # ==========================================================================
  # Basic Cognition (Original)
  # ==========================================================================

  def think(thought) do
    Logger.info("[THINK] #{thought}")
    {:ok, %{status: "recorded", thought: thought, timestamp: DateTime.utc_now()}}
  end

  def plan(steps) when is_list(steps) do
    Logger.info("[PLAN] #{length(steps)} steps recorded")

    formatted_steps =
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, idx} -> "#{idx}. #{step}" end)
      |> Enum.join("\n")

    {:ok, %{status: "recorded", steps: steps, formatted: formatted_steps}}
  end

  def plan(steps) when is_binary(steps) do
    plan([steps])
  end

  # ==========================================================================
  # Sequential Thinking (replaces sequential_thinking MCP server)
  # ==========================================================================

  @doc """
  Record a sequential thought as part of a structured problem-solving process.

  ## Parameters
  - thought: The content of this thought step
  - thought_number: Current step number (1-indexed)
  - total_thoughts: Expected total number of thoughts
  - next_thought_needed: Whether more thoughts are needed after this

  ## Returns
  - {:ok, %{...}} with session info and whether to continue
  """
  def sequential_thinking(params) when is_map(params) do
    ensure_started()

    thought = Map.get(params, "thought") || Map.get(params, :thought, "")
    thought_number = Map.get(params, "thoughtNumber") || Map.get(params, :thought_number, 1)
    total_thoughts = Map.get(params, "totalThoughts") || Map.get(params, :total_thoughts, 1)

    next_needed =
      Map.get(params, "nextThoughtNeeded") || Map.get(params, :next_thought_needed, false)

    session_id = get_or_create_session()

    thought_record = %{
      number: thought_number,
      content: thought,
      timestamp: DateTime.utc_now()
    }

    # Update session with new thought
    Agent.update(__MODULE__, fn state ->
      session = Map.get(state.sessions, session_id, %{thoughts: [], total: total_thoughts})

      updated_session = %{
        session
        | thoughts: session.thoughts ++ [thought_record],
          total: total_thoughts
      }

      %{state | sessions: Map.put(state.sessions, session_id, updated_session)}
    end)

    # Log for visibility
    Logger.info(
      "[SEQUENTIAL_THINKING] Step #{thought_number}/#{total_thoughts}: #{String.slice(thought, 0, 100)}..."
    )

    # Get session summary
    session_data =
      Agent.get(__MODULE__, fn state ->
        Map.get(state.sessions, session_id, %{thoughts: [], total: total_thoughts})
      end)

    progress = thought_number / max(total_thoughts, 1) * 100

    {:ok,
     %{
       session_id: session_id,
       thought_number: thought_number,
       total_thoughts: total_thoughts,
       progress_percent: Float.round(progress, 1),
       thoughts_recorded: length(session_data.thoughts),
       next_thought_needed: next_needed,
       status: if(next_needed, do: "continue", else: "complete")
     }}
  end

  @doc """
  Get the current thinking session's thoughts.
  """
  def get_session_thoughts(session_id \\ nil) do
    ensure_started()

    sid = session_id || Agent.get(__MODULE__, fn state -> state.current_session end)

    if sid do
      session =
        Agent.get(__MODULE__, fn state ->
          Map.get(state.sessions, sid, %{thoughts: [], total: 0})
        end)

      {:ok,
       %{
         session_id: sid,
         thoughts: session.thoughts,
         total_expected: session.total,
         total_recorded: length(session.thoughts)
       }}
    else
      {:error, "No active thinking session"}
    end
  end

  @doc """
  Clear the current thinking session and start fresh.
  """
  def reset_session do
    ensure_started()

    new_session_id = generate_session_id()

    Agent.update(__MODULE__, fn state ->
      %{state | current_session: new_session_id}
    end)

    {:ok, %{session_id: new_session_id, status: "new_session_started"}}
  end

  @doc """
  Get summary of all thinking sessions.
  """
  def list_sessions do
    ensure_started()

    sessions =
      Agent.get(__MODULE__, fn state ->
        Enum.map(state.sessions, fn {id, data} ->
          %{
            session_id: id,
            thought_count: length(data.thoughts),
            expected_total: data.total,
            first_thought: List.first(data.thoughts),
            last_thought: List.last(data.thoughts)
          }
        end)
      end)

    current = Agent.get(__MODULE__, fn state -> state.current_session end)

    {:ok, %{sessions: sessions, current_session: current, total_sessions: length(sessions)}}
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp get_or_create_session do
    current = Agent.get(__MODULE__, fn state -> state.current_session end)

    if current do
      current
    else
      new_id = generate_session_id()

      Agent.update(__MODULE__, fn state ->
        %{
          state
          | current_session: new_id,
            sessions: Map.put(state.sessions, new_id, %{thoughts: [], total: 0})
        }
      end)

      new_id
    end
  end

  defp generate_session_id do
    "thinking_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(9999)}"
  end
end
