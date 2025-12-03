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

  @doc """
  Returns all MCP tool definitions.
  """
  def list_tools, do: Definitions.definitions()

  @doc """
  Dispatch a tool call to the appropriate handler.
  """
  def dispatch(tool_name, arguments \\ %{}) do
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
         "Unknown tool: #{tool_name}. Available: file, terminal, web, fetch, search, blink, browser, vision, sonar, web_extract, web_parse, think, cognitive, reason, knowledge, code, code_symbols, library, diagnostics, verify, graph, onboard, meta, analyze_file, debug_error, prepare_context, suggest_next_tool, emergence, reflector"}
    end
  end
end
