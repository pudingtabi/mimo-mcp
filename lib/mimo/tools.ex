defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher - Facade module.

  This is the public API for Mimo's native tools. It delegates to modular
  dispatcher modules for actual implementation.

  ## Tool Architecture (After Phase 1-4 Consolidation)

  Mimo provides 17 primary tools with 12 deprecated aliases for backward compatibility.

  ### Primary Tools (17)

  1. `file` - All file operations (read, write, ls, search, edit, glob, etc.)
  2. `terminal` - All terminal/process operations
  3. `web` - **UNIFIED** All web operations (fetch, search, blink, browser, vision, sonar, extract, parse)
  4. `code` - **UNIFIED** All code intelligence (symbols, library, diagnostics)
  5. `think` - Cognitive operations (thought, plan, sequential)
  6. `knowledge` - Knowledge graph operations (SemanticStore + Synapse)
  7. `cognitive` - Meta-cognition, verification, emergence, reflector operations
  8. `reason` - Unified reasoning engine (CoT, ToT, ReAct, Reflexion)
  9. `onboard` - Project initialization meta-tool
  10. `meta` - Unified composite operations (analyze_file, debug_error, prepare_context, suggest_next_tool)
  11. `analyze_file` - Composite: file + symbols + diagnostics + knowledge
  12. `debug_error` - Composite: memory + symbols + diagnostics
  13. `prepare_context` - Smart context aggregation
  14. `suggest_next_tool` - Workflow guidance
  15. `emergence` - Pattern detection (SPEC-044)
  16. `reflector` - Self-reflection (SPEC-043)
  17. `verify` - Executable verification (SPEC-AI-TEST)

  ### Deprecated Tools (12) - Redirect to Unified

  - `fetch`, `search`, `blink`, `browser`, `vision`, `sonar`, `web_extract`, `web_parse` → `web`
  - `code_symbols`, `library`, `diagnostics` → `code`
  - `graph` → `knowledge`

  ## Architecture (SPEC-030)

  This module is a thin facade that delegates to:
  - `Mimo.Tools.Definitions` - Tool JSON schemas for MCP
  - `Mimo.Tools.Helpers` - Shared utilities
  - `Mimo.Tools.Dispatchers.*` - Per-tool dispatchers
  """

  require Logger

  alias Mimo.Tools.{Definitions, Dispatchers}
  alias Mimo.Knowledge.InjectionMiddleware

  @doc """
  Returns all MCP tool definitions.
  """
  def list_tools, do: Definitions.definitions()

  @doc """
  Dispatch a tool call to the appropriate handler.

  SPEC-065: Wraps dispatch with knowledge injection middleware.
  Returns the tool result enriched with any relevant injected knowledge.

  A/B Testing: For sessions in the test group, pattern suggestions from
  promoted emergence patterns are injected into the result.
  """
  def dispatch(tool_name, arguments \\ %{}) do
    # Track tool usage for adoption metrics (measures AUTO-REASONING workflow adoption)
    Mimo.AdoptionMetrics.track_tool_call(tool_name)

    # A/B Testing: Get pattern suggestions for test group sessions
    ab_suggestions = get_ab_suggestions(tool_name, arguments)

    # SPEC-065: Wrap with knowledge injection middleware
    {result, injection} =
      InjectionMiddleware.wrap_dispatch(tool_name, arguments, fn ->
        do_dispatch(tool_name, arguments)
      end)

    # Determine if the result indicates success (for A/B testing outcome tracking)
    track_ab_outcome(result)

    # If there's injection data, enrich the result
    case {result, injection} do
      {result, nil} ->
        maybe_add_ab_suggestions(result, ab_suggestions)

      {{:ok, data}, injection} when is_map(data) and is_map(injection) ->
        # Add injection as metadata the AI can see
        enriched = Map.put(data, :_mimo_knowledge_injection, format_injection(injection))
        maybe_add_ab_suggestions({:ok, enriched}, ab_suggestions)

      {result, _injection} ->
        maybe_add_ab_suggestions(result, ab_suggestions)
    end
  end

  @doc """
  Dispatch without injection middleware (for internal use or testing).
  """
  def dispatch_raw(tool_name, arguments \\ %{}) do
    do_dispatch(tool_name, arguments)
  end

  # Format injection for response
  defp format_injection(injection) do
    %{
      memories: Map.get(injection, :memories, []),
      source: Map.get(injection, :source, "SPEC-065"),
      hint: "💡 Mimo surfaced this knowledge proactively based on your action"
    }
  end

  # ============================================================================
  # A/B Testing Helpers
  # ============================================================================

  # Get A/B testing pattern suggestions for test group sessions
  defp get_ab_suggestions(tool_name, arguments) do
    alias Mimo.Brain.Emergence.ABTesting

    # Only run A/B testing for certain "action" tools where patterns apply
    if ab_testing_applicable?(tool_name) do
      context = build_ab_context(tool_name, arguments)
      ABTesting.get_suggestions(tool_name, context)
    else
      {:control, nil}
    end
  rescue
    # Don't let A/B testing failures break normal dispatch
    _ -> {:control, nil}
  end

  # Track outcome for A/B testing
  defp track_ab_outcome(result) do
    alias Mimo.Brain.Emergence.ABTesting

    success? = case result do
      {:ok, _} -> true
      :ok -> true
      {:error, _} -> false
      _ -> true  # Assume success for ambiguous results
    end

    ABTesting.track_outcome(success?)
  rescue
    _ -> :ok
  end

  # Add A/B test suggestions to result if applicable
  defp maybe_add_ab_suggestions(result, {:test, suggestions}) when suggestions != [] do
    case result do
      {:ok, data} when is_map(data) ->
        {:ok, Map.put(data, :_mimo_pattern_suggestions, %{
          source: "emergence_ab_test",
          group: :test,
          suggestions: suggestions,
          hint: "💡 These patterns have been promoted from observed agent behaviors"
        })}

      other ->
        other
    end
  end

  defp maybe_add_ab_suggestions(result, _), do: result

  # Determine which tools are applicable for A/B testing pattern injection
  defp ab_testing_applicable?(tool_name) do
    # Apply to "action" tools where patterns might help
    tool_name in ["file", "terminal", "code", "web", "knowledge"]
  end

  # Build context for pattern suggestion matching
  defp build_ab_context(tool_name, arguments) do
    operation = arguments["operation"] || "default"
    
    %{
      tool: tool_name,
      operation: operation,
      has_path: Map.has_key?(arguments, "path"),
      has_query: Map.has_key?(arguments, "query"),
      has_command: Map.has_key?(arguments, "command")
    }
  end

  # The actual dispatch logic
  defp do_dispatch(tool_name, arguments) do
    case tool_name do
      # File operations
      "file" ->
        Dispatchers.File.dispatch(arguments)

      # Terminal operations
      "terminal" ->
        Dispatchers.Terminal.dispatch(arguments)

      # =================================================================
      # WEB TOOL (Unified - Phase 4)
      # =================================================================
      # Consolidates: fetch, search, blink, browser, vision, sonar,
      #               web_extract, web_parse
      # =================================================================
      "web" ->
        Dispatchers.Web.dispatch(arguments)

      # Legacy web tools - redirect to unified dispatcher
      "fetch" ->
        # DEPRECATED: Use `web operation=fetch` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "fetch"))

      "search" ->
        # DEPRECATED: Use `web operation=search` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "search"))

      "blink" ->
        # DEPRECATED: Use `web operation=blink` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "blink"))

      "browser" ->
        # DEPRECATED: Use `web operation=browser` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "browser"))

      "vision" ->
        # DEPRECATED: Use `web operation=vision` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "vision"))

      "sonar" ->
        # DEPRECATED: Use `web operation=sonar` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "sonar"))

      "web_extract" ->
        # DEPRECATED: Use `web operation=extract` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "extract"))

      "web_parse" ->
        # DEPRECATED: Use `web operation=parse` instead
        Dispatchers.Web.dispatch(Map.put(arguments, "operation", "parse"))

      # Cognitive operations
      "think" ->
        Dispatchers.Cognitive.dispatch_think(arguments)

      "cognitive" ->
        Dispatchers.Cognitive.dispatch(arguments)

      "reason" ->
        Dispatchers.Cognitive.dispatch_reason(arguments)

      # Knowledge graph operations
      "knowledge" ->
        Dispatchers.Knowledge.dispatch(arguments)

      "graph" ->
        # DEPRECATED: Redirect to unified knowledge tool
        Logger.warning(
          "[DEPRECATED] 'graph' tool is deprecated. Use 'knowledge' tool instead with same operations."
        )

        Dispatchers.Knowledge.dispatch(arguments)

      # Unified Code Intelligence (SPEC-030 Phase 3 consolidation)
      "code" ->
        Dispatchers.Code.dispatch(arguments)

      # Legacy code_symbols → code tool
      "code_symbols" ->
        Logger.debug("[LEGACY] 'code_symbols' tool called - consider using 'code operation=...'")
        Dispatchers.Code.dispatch(arguments)

      # Legacy library → code tool with library_* operations
      "library" ->
        Logger.debug(
          "[LEGACY] 'library' tool called - consider using 'code operation=library|library_search|library_ensure|library_discover|library_stats'"
        )

        # Map legacy library operations to new code tool operations
        op = arguments["operation"] || "get"

        new_op =
          case op do
            "get" -> "library_get"
            "search" -> "library_search"
            "ensure" -> "library_ensure"
            "discover" -> "library_discover"
            "stats" -> "library_stats"
            _ -> "library_get"
          end

        Dispatchers.Code.dispatch(Map.put(arguments, "operation", new_op))

      # Legacy diagnostics → code tool with check/lint/typecheck/diagnose operations
      "diagnostics" ->
        Logger.debug(
          "[LEGACY] 'diagnostics' tool called - consider using 'code operation=check|lint|typecheck|diagnose'"
        )

        # Map legacy diagnostics operations to new code tool operations
        op = arguments["operation"] || "all"

        new_op =
          case op do
            "all" -> "diagnostics_all"
            "check" -> "check"
            "lint" -> "lint"
            "typecheck" -> "typecheck"
            _ -> "diagnostics_all"
          end

        Dispatchers.Code.dispatch(Map.put(arguments, "operation", new_op))

      # Verification (SPEC-AI-TEST)
      "verify" ->
        Dispatchers.Verify.dispatch(arguments)

      # Project onboarding (SPEC-031 Phase 3)
      "onboard" ->
        Dispatchers.Onboard.dispatch(arguments)

      # Compound domain actions (SPEC-031 Phase 5) - Now consolidated into meta tool
      # Legacy standalone interfaces still work but redirect to meta dispatcher
      "meta" ->
        Dispatchers.Meta.dispatch(arguments)

      "analyze_file" ->
        Logger.debug(
          "[LEGACY] 'analyze_file' tool called - consider using 'meta operation=analyze_file'"
        )

        Dispatchers.Meta.dispatch_analyze_file(arguments)

      "debug_error" ->
        Logger.debug(
          "[LEGACY] 'debug_error' tool called - consider using 'meta operation=debug_error'"
        )

        Dispatchers.Meta.dispatch_debug_error(arguments)

      "prepare_context" ->
        Logger.debug(
          "[LEGACY] 'prepare_context' tool called - consider using 'meta operation=prepare_context'"
        )

        Dispatchers.Meta.dispatch_prepare_context(arguments)

      "suggest_next_tool" ->
        Logger.debug(
          "[LEGACY] 'suggest_next_tool' tool called - consider using 'meta operation=suggest_next_tool'"
        )

        Dispatchers.Meta.dispatch_suggest_next_tool(arguments)

      # Emergent Capabilities (SPEC-044)
      "emergence" ->
        Dispatchers.Emergence.dispatch(arguments)

      # Reflective Intelligence (SPEC-043)
      "reflector" ->
        Dispatchers.Reflector.dispatch(arguments)

      # Autonomous Task Execution (SPEC-071)
      "autonomous" ->
        Dispatchers.Autonomous.dispatch(arguments)

      # Legacy aliases for backward compatibility
      "http_request" ->
        Dispatchers.Web.dispatch_fetch(Map.put(arguments, "format", "raw"))

      "plan" ->
        Dispatchers.Cognitive.dispatch_think(
          Map.merge(arguments, %{"operation" => "plan", "thought" => "plan"})
        )

      "consult_graph" ->
        Logger.warning(
          "[DEPRECATED] 'consult_graph' is deprecated. Use 'knowledge operation=query' instead."
        )

        Dispatchers.Knowledge.dispatch(Map.put(arguments, "operation", "query"))

      "teach_mimo" ->
        Logger.warning(
          "[DEPRECATED] 'teach_mimo' is deprecated. Use 'knowledge operation=teach' instead."
        )

        Dispatchers.Knowledge.dispatch(Map.put(arguments, "operation", "teach"))

      _ ->
        {:error,
         "Unknown tool: #{tool_name}. Available: file, terminal, web, code, knowledge, cognitive, reason, think, onboard, meta, autonomous, emergence, reflector, verify. Deprecated but working: fetch, search, blink, browser, vision, sonar, web_extract, web_parse, code_symbols, library, diagnostics, graph, analyze_file, debug_error, prepare_context, suggest_next_tool"}
    end
  end
end
