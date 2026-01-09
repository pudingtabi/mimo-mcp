defmodule Mimo.Gateway do
  @moduledoc """
  Mimo Gateway - The Iron Man Suit for LLMs.

  SPEC-091: External Enforcement Layer

  The Gateway is a multi-layer enforcement system that ensures LLMs
  follow best practices regardless of their training habits:

  1. **Input Gate** - Prerequisite checks before tool execution
  2. **Runtime Guard** - Phase tracking and resource budgets
  3. **Output Validator** - Verification and quality checks

  ## Philosophy

  > "Mimo is the suit. The LLM is the pilot."

  Any LLM connected to Mimo gets:
  - Forced reasoning before action (no skipping Phase 0)
  - Automatic context injection
  - Verification enforcement
  - Learning from every interaction

  ## Usage

      # All tool calls go through the Gateway
      Mimo.Gateway.execute(session, "file", %{"operation" => "edit", ...})

      # The Gateway enforces:
      # - reason/memory called before file edit
      # - Phase ordering respected
      # - Verification claims have proof
  """

  require Logger

  alias Mimo.Gateway.{InputGate, QualityGate, RuntimeGuard, OutputValidator, Session}

  @doc """
  Execute a tool call through the Gateway enforcement layers.
  """
  def execute(session_id, tool_name, arguments) do
    with {:ok, session} <- Session.get_or_create(session_id),
         # Layer 1: Basic prerequisite check
         {:ok, session, args} <- InputGate.check(session, tool_name, arguments),
         # Layer 2: QUALITY check (the real enforcement - uses ThoughtEvaluator)
         {:ok, session, args} <- QualityGate.check_quality(session, tool_name, args),
         # Layer 3: Runtime monitoring
         {:ok, session} <- RuntimeGuard.enter(session, tool_name),
         {:ok, result} <- execute_tool(tool_name, args),
         {:ok, session, result} <- OutputValidator.validate(session, tool_name, result),
         {:ok, session} <- RuntimeGuard.exit(session, tool_name, result) do
      Session.update(session)
      {:ok, result}
    else
      {:blocked, reason, suggestion} ->
        Logger.info("[Gateway] Blocked #{tool_name}: #{reason}")
        {:error, {:gateway_blocked, reason, suggestion}}

      {:warn, warning, result} ->
        Logger.info("[Gateway] Warning for #{tool_name}: #{warning}")
        {:ok, add_warning(result, warning)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a tool call would be allowed (without executing).
  """
  def would_allow?(session_id, tool_name, arguments) do
    case Session.get_or_create(session_id) do
      {:ok, session} ->
        case InputGate.check(session, tool_name, arguments) do
          {:ok, _, _} -> {:ok, :allowed}
          {:blocked, reason, suggestion} -> {:blocked, reason, suggestion}
        end

      error ->
        error
    end
  end

  # Execute the actual tool (bypass to existing dispatcher)
  defp execute_tool(tool_name, arguments) do
    Mimo.Tools.dispatch(tool_name, arguments)
  end

  defp add_warning(result, warning) when is_map(result) do
    warnings = Map.get(result, :gateway_warnings, [])
    Map.put(result, :gateway_warnings, [warning | warnings])
  end

  defp add_warning(result, _warning), do: result
end
