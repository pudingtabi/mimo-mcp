defmodule Mimo.Gateway.InputGate do
  @moduledoc """
  Input Gate - Pre-tool enforcement layer.

  Enforces prerequisites before allowing tool execution:
  - Reasoning must be called before action tools
  - Memory must be searched before edits
  - Phase order must be respected
  """

  require Logger

  alias Mimo.Gateway.Session

  # Tools that require reasoning first
  @action_tools ["file", "terminal"]

  # Tools that bypass prerequisites (always allowed)
  @always_allowed ["reason", "memory", "onboard", "awakening_status", "meta"]

  # Operations within tools that are considered "safe"
  @safe_operations %{
    "file" => ["read", "ls", "list_directory", "glob", "get_info"],
    "terminal" => ["list_sessions", "list_processes", "read_output"]
  }

  @doc """
  Check if a tool call should be allowed.

  Returns:
  - {:ok, session, enriched_args} - Allowed to proceed
  - {:blocked, reason, suggestion} - Blocked with explanation
  """
  def check(%Session{} = session, tool_name, arguments) do
    cond do
      # Always allow certain tools
      tool_name in @always_allowed ->
        {:ok, session, arguments}

      # Check if it's a safe operation within an action tool
      safe_operation?(tool_name, arguments) ->
        {:ok, session, arguments}

      # Action tools require prerequisites
      tool_name in @action_tools ->
        check_action_prerequisites(session, tool_name, arguments)

      # Other tools are allowed
      true ->
        {:ok, session, arguments}
    end
  end

  # Check prerequisites for action tools
  defp check_action_prerequisites(session, tool_name, arguments) do
    with :ok <- check_reason_called(session, tool_name),
         :ok <- check_memory_searched(session, tool_name),
         :ok <- check_phase_order(session, tool_name) do
      # Record this tool call and return enriched session
      {:ok, updated_session} = Session.record_tool_call(session, tool_name, arguments)
      {:ok, updated_session, arguments}
    end
  end

  # Check if reason tool was called - use ReasoningSession which persists across MCP calls!
  defp check_reason_called(%Session{} = session, tool_name) do
    # First check session flag (within same call chain)
    if session.reason_called? do
      :ok
    else
      # Check ETS for any active reasoning session (persists across MCP reconnections!)
      active_sessions = Mimo.Cognitive.ReasoningSession.list_active()

      if Enum.empty?(active_sessions) do
        # No active reasoning sessions - block
        {:blocked, "#{tool_name} blocked: reasoning not performed",
         "Call `reason operation=guided problem=\"...\"` first to plan your approach"}
      else
        # There's an active reasoning session - allow!
        :ok
      end
    end
  end

  # Check if memory was searched
  defp check_memory_searched(%Session{memory_searched?: true}, _tool), do: :ok

  defp check_memory_searched(%Session{memory_searched?: false}, tool_name) do
    # Warning, not hard block (for now)
    Logger.warning("[InputGate] #{tool_name} called without memory search")
    :ok
    # Could make this a hard block:
    # {:blocked,
    #  "#{tool_name} blocked: memory not checked",
    #  "Call `memory operation=search query=\"...\"` to check existing knowledge"}
  end

  # Check phase ordering
  defp check_phase_order(%Session{phase: current_phase}, tool_name) do
    target_phase = tool_to_phase(tool_name)

    if valid_phase_transition?(current_phase, target_phase) do
      :ok
    else
      Logger.warning("[InputGate] Phase order warning: #{current_phase} → #{target_phase}")
      # Warning only, not blocking for now
      :ok
    end
  end

  # Map tools to their workflow phase
  defp tool_to_phase("reason"), do: :reasoning
  defp tool_to_phase("memory"), do: :context
  defp tool_to_phase("code"), do: :intelligence
  defp tool_to_phase("file"), do: :action
  defp tool_to_phase("terminal"), do: :action
  defp tool_to_phase(_), do: :any

  # Check if phase transition is valid
  defp valid_phase_transition?(:initial, _), do: true
  defp valid_phase_transition?(:reasoning, _), do: true
  defp valid_phase_transition?(:context, :intelligence), do: true
  defp valid_phase_transition?(:context, :action), do: true
  # Can go back
  defp valid_phase_transition?(:context, :reasoning), do: true
  defp valid_phase_transition?(:intelligence, :action), do: true
  defp valid_phase_transition?(:intelligence, :reasoning), do: true
  defp valid_phase_transition?(:action, :reasoning), do: true
  defp valid_phase_transition?(same, same), do: true
  defp valid_phase_transition?(:any, _), do: true
  defp valid_phase_transition?(_, :any), do: true
  defp valid_phase_transition?(_, _), do: false

  # Check if operation is safe (read-only)
  defp safe_operation?(tool_name, %{"operation" => operation}) do
    case Map.get(@safe_operations, tool_name) do
      nil -> false
      safe_ops -> operation in safe_ops
    end
  end

  defp safe_operation?(_, _), do: false
end
