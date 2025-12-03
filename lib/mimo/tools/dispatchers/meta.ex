defmodule Mimo.Tools.Dispatchers.Meta do
  @moduledoc """
  Unified Meta Tool Dispatcher - Phase 2 Consolidation

  Consolidates 4 composite/orchestration tools into a single unified interface:
  - analyze_file: Unified file analysis (file + symbols + diagnostics + knowledge)
  - debug_error: Error debugging assistant (memory + symbols + diagnostics)
  - prepare_context: Smart context aggregation (memory + knowledge + code + library)
  - suggest_next_tool: Workflow guidance based on task

  ## Usage

      # New unified interface
      meta operation=analyze_file path="src/app.ts"
      meta operation=debug_error message="undefined function"
      meta operation=prepare_context query="implement auth"
      meta operation=suggest_next_tool task="fix this bug"
      
      # Legacy standalone tools still work (with deprecation warning)
      analyze_file path="src/app.ts"
  """

  require Logger

  alias Mimo.Tools.Dispatchers.{
    AnalyzeFile,
    DebugError,
    PrepareContext,
    SuggestNextTool
  }

  @operations [
    "analyze_file",
    "debug_error",
    "prepare_context",
    "suggest_next_tool"
  ]

  @doc """
  Dispatch meta tool operations.

  ## Parameters
    - operation: One of #{inspect(@operations)}
    - ... additional parameters passed to the specific operation
  """
  def dispatch(args) do
    operation = args["operation"] || "analyze_file"

    case operation do
      "analyze_file" ->
        dispatch_analyze_file(args)

      "debug_error" ->
        dispatch_debug_error(args)

      "prepare_context" ->
        dispatch_prepare_context(args)

      "suggest_next_tool" ->
        dispatch_suggest_next_tool(args)

      unknown ->
        {:error, "Unknown meta operation: #{unknown}. Valid operations: #{inspect(@operations)}"}
    end
  end

  # ==========================================================================
  # OPERATION DISPATCHERS
  # ==========================================================================

  @doc """
  Dispatch analyze_file operation.

  Chains file read → code_symbols → diagnostics → knowledge for unified analysis.
  """
  def dispatch_analyze_file(args) do
    Logger.debug("[Meta] Dispatching analyze_file")
    AnalyzeFile.dispatch(args)
  end

  @doc """
  Dispatch debug_error operation.

  Searches memory for past solutions, looks up symbol definitions, gets diagnostics.
  """
  def dispatch_debug_error(args) do
    Logger.debug("[Meta] Dispatching debug_error")
    DebugError.dispatch(args)
  end

  @doc """
  Dispatch prepare_context operation.

  Aggregates context from memory + knowledge + code + library in parallel.
  """
  def dispatch_prepare_context(args) do
    Logger.debug("[Meta] Dispatching prepare_context")
    PrepareContext.dispatch(args)
  end

  @doc """
  Dispatch suggest_next_tool operation.

  Analyzes task and recent tool usage to suggest optimal next tool.
  """
  def dispatch_suggest_next_tool(args) do
    Logger.debug("[Meta] Dispatching suggest_next_tool")
    SuggestNextTool.dispatch(args)
  end
end
