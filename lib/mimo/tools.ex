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

  alias Mimo.Knowledge.InjectionMiddleware
  alias Mimo.Tools.{Definitions, Dispatchers}

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

  SPEC-083: Intelligent Dispatch adds pre-execution checks for Tier 2+
  operations (mutating/destructive), searching memory for past failures
  and relevant warnings before execution.
  """
  def dispatch(tool_name, arguments \\ %{}) do
    alias Mimo.Knowledge.IntelligentMiddleware

    # Telemetry: track dispatch start
    start_time = System.monotonic_time(:millisecond)
    metadata = %{tool: tool_name, operation: arguments["operation"]}
    :telemetry.execute([:mimo, :tool, :start], %{}, metadata)

    # Track tool usage for adoption metrics (measures AUTO-REASONING workflow adoption)
    Mimo.AdoptionMetrics.track_tool_call(tool_name)

    # Record activity for BackgroundCognition (prevents background cycles during active sessions)
    Mimo.Brain.BackgroundCognition.record_activity()

    # SPEC-083: Pre-dispatch intelligence check
    pre_context = IntelligentMiddleware.pre_dispatch(tool_name, arguments)

    # A/B Testing: Get pattern suggestions for test group sessions
    ab_suggestions = get_ab_suggestions(tool_name, arguments)

    # SPEC-065: Wrap with knowledge injection middleware
    {result, injection} =
      InjectionMiddleware.wrap_dispatch(tool_name, arguments, fn ->
        do_dispatch(tool_name, arguments)
      end)

    # SPEC-083: Post-dispatch learning (track outcome for future)
    IntelligentMiddleware.post_dispatch(tool_name, arguments, result, pre_context)

    # Telemetry: track dispatch completion
    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:mimo, :tool, :stop],
      %{duration_ms: duration_ms},
      Map.put(metadata, :success, match?({:ok, _}, result))
    )

    # Determine if the result indicates success (for A/B testing outcome tracking)
    track_ab_outcome(result)

    # SPEC-083: Enrich with intelligent dispatch context
    result_with_intel = IntelligentMiddleware.enrich_result(result, pre_context)

    # If there's injection data, enrich the result with injection + suggestions
    case {result_with_intel, injection} do
      {result, nil} ->
        # Add contextual tool suggestions even without injection
        with_suggestions = add_tool_suggestions(result, tool_name, arguments)
        maybe_add_ab_suggestions(with_suggestions, ab_suggestions)

      {{:ok, data}, injection} when is_map(data) and is_map(injection) ->
        # Add injection as metadata the AI can see
        enriched = Map.put(data, :_mimo_knowledge_injection, format_injection(injection))
        with_suggestions = add_tool_suggestions({:ok, enriched}, tool_name, arguments)
        maybe_add_ab_suggestions(with_suggestions, ab_suggestions)

      {result, _injection} ->
        with_suggestions = add_tool_suggestions(result, tool_name, arguments)
        maybe_add_ab_suggestions(with_suggestions, ab_suggestions)
    end
  end

  # Add contextual tool suggestions to help agents discover underused tools
  defp add_tool_suggestions({:ok, data}, tool_name, args) when is_map(data) do
    suggestions = InjectionMiddleware.format_for_response({:ok, data}, nil, tool_name, args)

    case Map.get(suggestions, :_mimo_suggestions) do
      nil -> {:ok, data}
      hints -> {:ok, Map.put(data, :_mimo_suggestions, hints)}
    end
  end

  defp add_tool_suggestions(result, _tool_name, _args), do: result

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
      hint: "auto-injected context"
    }
  end

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

    success? =
      case result do
        {:ok, _} -> true
        :ok -> true
        {:error, _} -> false
        # Assume success for ambiguous results
        _ -> true
      end

    ABTesting.track_outcome(success?)
  rescue
    _ -> :ok
  end

  # Add A/B test suggestions to result if applicable
  defp maybe_add_ab_suggestions(result, {:test, suggestions}) when suggestions != [] do
    case result do
      {:ok, data} when is_map(data) ->
        {:ok,
         Map.put(data, :_mimo_pattern_suggestions, %{
           source: "emergence_ab_test",
           group: :test,
           suggestions: suggestions,
           hint: "These patterns have been promoted from observed agent behaviors"
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

  # --- Primary Tools ---
  defp do_dispatch("file", args), do: Dispatchers.File.dispatch(args)
  defp do_dispatch("terminal", args), do: Dispatchers.Terminal.dispatch(args)
  defp do_dispatch("web", args), do: Dispatchers.Web.dispatch(args)
  defp do_dispatch("code", args), do: Dispatchers.Code.dispatch(args)
  defp do_dispatch("knowledge", args), do: Dispatchers.Knowledge.dispatch(args)
  defp do_dispatch("cognitive", args), do: Dispatchers.Cognitive.dispatch(args)
  defp do_dispatch("think", args), do: Dispatchers.Cognitive.dispatch_think(args)
  defp do_dispatch("reason", args), do: Dispatchers.Cognitive.dispatch_reason(args)
  defp do_dispatch("onboard", args), do: Dispatchers.Onboard.dispatch(args)
  defp do_dispatch("meta", args), do: Dispatchers.Meta.dispatch(args)
  defp do_dispatch("emergence", args), do: Dispatchers.Emergence.dispatch(args)
  defp do_dispatch("reflector", args), do: Dispatchers.Reflector.dispatch(args)
  defp do_dispatch("autonomous", args), do: Dispatchers.Autonomous.dispatch(args)
  defp do_dispatch("verify", args), do: Dispatchers.Verify.dispatch(args)
  defp do_dispatch("orchestrate", args), do: Dispatchers.Orchestrate.dispatch(args)

  # --- Legacy Web Tools (redirect to unified web dispatcher) ---
  defp do_dispatch("fetch", args), do: dispatch_legacy_web("fetch", args)
  defp do_dispatch("search", args), do: dispatch_legacy_web("search", args)
  defp do_dispatch("blink", args), do: dispatch_legacy_web("blink", args)
  defp do_dispatch("browser", args), do: dispatch_legacy_web("browser", args)
  defp do_dispatch("vision", args), do: dispatch_legacy_web("vision", args)
  defp do_dispatch("sonar", args), do: dispatch_legacy_web("sonar", args)
  defp do_dispatch("web_extract", args), do: dispatch_legacy_web("extract", args)
  defp do_dispatch("web_parse", args), do: dispatch_legacy_web("parse", args)

  defp do_dispatch("http_request", args),
    do: Dispatchers.Web.dispatch_fetch(Map.put(args, "format", "raw"))

  # --- Legacy Code Tools ---
  defp do_dispatch("code_symbols", args) do
    Logger.debug("[LEGACY] 'code_symbols' tool called - consider using 'code operation=...'")
    Dispatchers.Code.dispatch(args)
  end

  defp do_dispatch("library", args), do: dispatch_legacy_library(args)
  defp do_dispatch("diagnostics", args), do: dispatch_legacy_diagnostics(args)

  # --- Legacy Knowledge Tools ---
  defp do_dispatch("graph", args), do: dispatch_legacy_graph(args)
  defp do_dispatch("consult_graph", args), do: dispatch_legacy_consult_graph(args)
  defp do_dispatch("teach_mimo", args), do: dispatch_legacy_teach_mimo(args)

  # --- Legacy Composite Tools (redirect to meta) ---
  defp do_dispatch("analyze_file", args) do
    Logger.debug(
      "[LEGACY] 'analyze_file' tool called - consider using 'meta operation=analyze_file'"
    )

    Dispatchers.Meta.dispatch_analyze_file(args)
  end

  defp do_dispatch("debug_error", args) do
    Logger.debug("[LEGACY] 'debug_error' tool called - consider using 'meta operation=debug_error'")
    Dispatchers.Meta.dispatch_debug_error(args)
  end

  defp do_dispatch("prepare_context", args) do
    Logger.debug(
      "[LEGACY] 'prepare_context' tool called - consider using 'meta operation=prepare_context'"
    )

    Dispatchers.Meta.dispatch_prepare_context(args)
  end

  defp do_dispatch("suggest_next_tool", args) do
    Logger.debug(
      "[LEGACY] 'suggest_next_tool' tool called - consider using 'meta operation=suggest_next_tool'"
    )

    Dispatchers.Meta.dispatch_suggest_next_tool(args)
  end

  defp do_dispatch("plan", args) do
    Dispatchers.Cognitive.dispatch_think(
      Map.merge(args, %{"operation" => "plan", "thought" => "plan"})
    )
  end

  # --- Unknown tool ---
  defp do_dispatch(unknown, _args) do
    {:error,
     "Unknown tool: #{unknown}. Available: file, terminal, web, code, knowledge, cognitive, reason, think, onboard, meta, autonomous, emergence, reflector, verify. Deprecated but working: fetch, search, blink, browser, vision, sonar, web_extract, web_parse, code_symbols, library, diagnostics, graph, analyze_file, debug_error, prepare_context, suggest_next_tool"}
  end

  defp dispatch_legacy_web(operation, args) do
    Dispatchers.Web.dispatch(Map.put(args, "operation", operation))
  end

  defp dispatch_legacy_library(args) do
    Logger.debug("[LEGACY] 'library' tool called - consider using 'code operation=library_*'")
    op = args["operation"] || "get"
    new_op = map_legacy_library_op(op)
    Dispatchers.Code.dispatch(Map.put(args, "operation", new_op))
  end

  defp map_legacy_library_op("get"), do: "library_get"
  defp map_legacy_library_op("search"), do: "library_search"
  defp map_legacy_library_op("ensure"), do: "library_ensure"
  defp map_legacy_library_op("discover"), do: "library_discover"
  defp map_legacy_library_op("stats"), do: "library_stats"
  defp map_legacy_library_op(_), do: "library_get"

  defp dispatch_legacy_diagnostics(args) do
    Logger.debug(
      "[LEGACY] 'diagnostics' tool called - consider using 'code operation=check|lint|...'"
    )

    op = args["operation"] || "all"
    new_op = map_legacy_diagnostics_op(op)
    Dispatchers.Code.dispatch(Map.put(args, "operation", new_op))
  end

  defp map_legacy_diagnostics_op("all"), do: "diagnostics_all"
  defp map_legacy_diagnostics_op("check"), do: "check"
  defp map_legacy_diagnostics_op("lint"), do: "lint"
  defp map_legacy_diagnostics_op("typecheck"), do: "typecheck"
  defp map_legacy_diagnostics_op(_), do: "diagnostics_all"

  defp dispatch_legacy_graph(args) do
    Logger.warning("[DEPRECATED] 'graph' tool is deprecated. Use 'knowledge' tool instead.")
    Dispatchers.Knowledge.dispatch(args)
  end

  defp dispatch_legacy_consult_graph(args) do
    Logger.warning(
      "[DEPRECATED] 'consult_graph' is deprecated. Use 'knowledge operation=query' instead."
    )

    Dispatchers.Knowledge.dispatch(Map.put(args, "operation", "query"))
  end

  defp dispatch_legacy_teach_mimo(args) do
    Logger.warning(
      "[DEPRECATED] 'teach_mimo' is deprecated. Use 'knowledge operation=teach' instead."
    )

    Dispatchers.Knowledge.dispatch(Map.put(args, "operation", "teach"))
  end
end
