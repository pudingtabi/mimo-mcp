defmodule Mimo.Tools.Dispatchers.SuggestNextTool do
  @moduledoc """
  Dispatcher for the suggest_next_tool meta-tool (SPEC-041 P4).

  Analyzes the current task and recent tool usage to recommend the optimal
  next tool according to the Mimo workflow: Context → Intelligence → Action → Learning.
  """

  require Logger

  # Tool categories for workflow phases
  @context_tools ~w(memory ask_mimo knowledge prepare_context)
  @intelligence_tools ~w(code_symbols diagnostics library cognitive reason)
  @action_tools ~w(file terminal fetch search blink browser)
  # @learning_tools is subset of other phases, kept for documentation
  # @learning_tools ~w(memory knowledge)

  # Keywords that suggest specific tools
  @package_keywords ~w(package library dependency npm pypi hex crates docs documentation)
  @code_keywords ~w(function class method definition symbol reference usage call)
  @error_keywords ~w(error bug fix debug crash exception failing broken)
  @architecture_keywords ~w(depends relationship architecture module service component)

  @doc """
  Dispatch the suggest_next_tool operation.
  """
  def dispatch(args) do
    task = Map.get(args, "task", "")
    recent_tools = Map.get(args, "recent_tools", []) |> normalize_tools()
    context = Map.get(args, "context", "")

    if task == "" do
      {:error, "task is required - describe what you're trying to accomplish"}
    else
      suggestion = analyze_and_suggest(task, recent_tools, context)
      {:ok, suggestion}
    end
  end

  # Normalize tool names (handle variations)
  defp normalize_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      tool
      |> to_string()
      |> String.downcase()
      |> String.replace("_", "")
    end)
  end

  defp normalize_tools(_), do: []

  # Main analysis logic
  defp analyze_and_suggest(task, recent_tools, context) do
    task_lower = String.downcase(task <> " " <> context)

    # Determine current workflow phase
    phase = determine_phase(recent_tools)

    # Check for workflow violations
    warnings = check_workflow_violations(task_lower, recent_tools, phase)

    # Generate suggestion based on task type and phase
    {suggested_tool, reason, alternatives} =
      suggest_for_task(task_lower, recent_tools, phase)

    %{
      suggested_tool: suggested_tool,
      reason: reason,
      workflow_phase: phase,
      alternatives: alternatives,
      warnings: warnings,
      recent_tools_recognized: recent_tools,
      workflow_guidance: get_phase_guidance(phase)
    }
  end

  # Determine which workflow phase the user is in
  defp determine_phase(recent_tools) do
    # Normalize tool names for comparison
    context_normalized = Enum.map(@context_tools, &String.replace(&1, "_", ""))
    intelligence_normalized = Enum.map(@intelligence_tools, &String.replace(&1, "_", ""))
    action_normalized = Enum.map(@action_tools, &String.replace(&1, "_", ""))

    has_context? = Enum.any?(recent_tools, fn tool -> tool in context_normalized end)
    has_intelligence? = Enum.any?(recent_tools, fn tool -> tool in intelligence_normalized end)
    has_action? = Enum.any?(recent_tools, fn tool -> tool in action_normalized end)

    cond do
      !has_context? -> :context
      !has_intelligence? and needs_intelligence?(recent_tools) -> :intelligence
      has_action? -> :learning
      true -> :action
    end
  end

  defp needs_intelligence?(recent_tools) do
    # If they've only done context gathering, they probably need intelligence tools
    length(recent_tools) <= 3
  end

  # Check for common workflow anti-patterns
  defp check_workflow_violations(task_lower, recent_tools, phase) do
    warnings = []

    # Warning: About to read file without memory check
    warnings =
      if phase == :context and
           (String.contains?(task_lower, "read") or String.contains?(task_lower, "file")) and
           "memory" not in recent_tools do
        [
          "⚠️ Consider searching memory first - you may already have context about this file"
          | warnings
        ]
      else
        warnings
      end

    # Warning: About to search for code without code_symbols
    warnings =
      if contains_any?(task_lower, @code_keywords) and
           "codesymbols" not in recent_tools and
           String.contains?(task_lower, "find") do
        ["⚠️ Use code_symbols for semantic code navigation instead of file search" | warnings]
      else
        warnings
      end

    # Warning: About to web search for package docs
    warnings =
      if contains_any?(task_lower, @package_keywords) and
           "library" not in recent_tools and
           String.contains?(task_lower, "search") do
        ["⚠️ Use library tool for package docs - it's instant and cached" | warnings]
      else
        warnings
      end

    # Warning: No learning after action
    warnings =
      if phase == :learning and
           "memory" not in recent_tools and
           length(recent_tools) > 5 do
        ["⚠️ Consider storing discoveries in memory so they persist" | warnings]
      else
        warnings
      end

    Enum.reverse(warnings)
  end

  # Suggest tool based on task content and phase
  defp suggest_for_task(task_lower, recent_tools, phase) do
    cond do
      # Phase-based defaults
      phase == :context and "memory" not in recent_tools ->
        {"memory", "Start with memory search to check existing context",
         ["ask_mimo", "prepare_context"]}

      phase == :context and "askmimo" not in recent_tools ->
        {"ask_mimo", "Consult Mimo for strategic guidance on this task", ["memory", "knowledge"]}

      # Task-specific suggestions
      contains_any?(task_lower, @package_keywords) and "library" not in recent_tools ->
        {"library", "Library provides instant cached package documentation", ["search"]}

      contains_any?(task_lower, @code_keywords) and "codesymbols" not in recent_tools ->
        {"code_symbols", "Semantic code navigation is faster and more accurate than grep",
         ["file search"]}

      contains_any?(task_lower, @error_keywords) ->
        if "diagnostics" in recent_tools do
          {"debug_error", "Use debug_error for comprehensive error analysis", ["file", "terminal"]}
        else
          {"diagnostics", "Get structured error output before debugging",
           ["debug_error", "terminal"]}
        end

      contains_any?(task_lower, @architecture_keywords) and "knowledge" not in recent_tools ->
        {"knowledge", "Query the knowledge graph for relationships and dependencies",
         ["code_symbols"]}

      # Phase-based action suggestions
      phase == :action ->
        {"file", "Context gathered, ready for file operations", ["terminal", "multi_replace"]}

      phase == :learning ->
        {"memory", "Store your discoveries in memory", ["knowledge teach"]}

      # Default to context if nothing else matches
      true ->
        {"memory", "When in doubt, search memory first", ["ask_mimo", "prepare_context"]}
    end
  end

  # Get guidance text for current phase
  defp get_phase_guidance(:context) do
    "📚 CONTEXT PHASE: Gather existing knowledge before acting. Use memory, ask_mimo, or knowledge."
  end

  defp get_phase_guidance(:intelligence) do
    "🧠 INTELLIGENCE PHASE: Use smart tools for analysis. Try code_symbols, diagnostics, or library."
  end

  defp get_phase_guidance(:action) do
    "⚡ ACTION PHASE: Context gathered, ready to make changes with file/terminal."
  end

  defp get_phase_guidance(:learning) do
    "📝 LEARNING PHASE: Store discoveries in memory and teach key relationships in the knowledge graph."
  end

  # Helper to check if string contains any of the keywords
  defp contains_any?(string, keywords) do
    Enum.any?(keywords, &String.contains?(string, &1))
  end
end
