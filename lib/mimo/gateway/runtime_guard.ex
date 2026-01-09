defmodule Mimo.Gateway.RuntimeGuard do
  @moduledoc """
  Runtime Guard - Monitoring during tool execution.

  Tracks:
  - Phase transitions
  - Resource budgets (optional)
  - Contradiction detection (optional)
  """

  require Logger

  alias Mimo.Gateway.Session

  @doc """
  Called before tool execution starts.
  """
  def enter(%Session{} = session, tool_name) do
    # Record the tool call
    {:ok, session} = Session.record_tool_call(session, tool_name)

    # Log phase transition if needed
    log_phase_transition(session, tool_name)

    {:ok, session}
  end

  @doc """
  Called after tool execution completes.
  """
  def exit(%Session{} = session, tool_name, result) do
    # Could add:
    # - Budget tracking (count edits, limit per session)
    # - Pattern detection (repeated similar actions)
    # - Auto-trigger reflection after action phase

    session = maybe_trigger_learning(session, tool_name, result)

    {:ok, session}
  end

  # Log phase transitions for debugging
  defp log_phase_transition(%Session{phase: phase}, tool_name) do
    Logger.debug("[RuntimeGuard] Tool: #{tool_name}, Phase: #{phase}")
  end

  # Trigger learning reminders after action phase
  defp maybe_trigger_learning(%Session{phase: :action} = session, tool_name, _result)
       when tool_name in ["file", "terminal"] do
    # Check if we should remind about learning phase
    action_count = count_actions(session)

    if action_count > 3 and not has_recent_reflection?(session) do
      Logger.info("[RuntimeGuard] Hint: Consider storing learnings with memory/reason reflect")
    end

    session
  end

  defp maybe_trigger_learning(session, _tool, _result), do: session

  defp count_actions(%Session{tool_history: history}) do
    Enum.count(history, fn %{tool: tool} ->
      tool in ["file", "terminal"]
    end)
  end

  defp has_recent_reflection?(%Session{tool_history: history}) do
    recent = Enum.take(history, 5)

    Enum.any?(recent, fn %{tool: tool, args: args} ->
      tool == "memory" or
        (tool == "reason" and Map.get(args, "operation") == "reflect")
    end)
  end
end
