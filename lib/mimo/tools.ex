defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher - Facade module.

  This is the public API for Mimo's native tools. It delegates to modular
  dispatcher modules for actual implementation.

  Consolidated native Elixir tools - fewer tools, more power.
  Each tool handles multiple operations via the 'operation' parameter.

  ## Core Tools

  1. `file` - All file operations (read, write, ls, search, info, etc.)
  2. `terminal` - All terminal/process operations
  3. `fetch` - All network operations (text, html, json, markdown)
  4. `think` - All cognitive operations (thought, plan, sequential)
  5. `web_parse` - Convert HTML to Markdown
  6. `search` - Web search via DuckDuckGo, Bing, or Brave (auto-fallback)
  7. `web_extract` - Extract clean content from web pages
  8. `sonar` - UI accessibility scanner
  9. `vision` - Image analysis via vision-capable LLM
  10. `knowledge` - Knowledge graph operations (SemanticStore + Synapse)
  11. `blink` - Enhanced web fetch with browser fingerprinting (HTTP-level)
  12. `browser` - Full browser automation with Puppeteer stealth
  13. `cognitive` - Epistemic uncertainty & meta-cognition (SPEC-024)
  14. `code_symbols` - Code structure analysis (Tree-Sitter)
  15. `library` - Package documentation lookup
  16. `diagnostics` - Compile/lint errors and warnings
  17. `graph` - [DEPRECATED] Redirects to knowledge tool

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

      # Web operations
      "fetch" ->
        Dispatchers.Web.dispatch_fetch(arguments)

      "search" ->
        Dispatchers.Web.dispatch_search(arguments)

      "blink" ->
        Dispatchers.Web.dispatch_blink(arguments)

      "browser" ->
        Dispatchers.Web.dispatch_browser(arguments)

      "vision" ->
        Dispatchers.Web.dispatch_vision(arguments)

      "sonar" ->
        Dispatchers.Web.dispatch_sonar(arguments)

      "web_extract" ->
        Dispatchers.Web.dispatch_web_extract(arguments)

      "web_parse" ->
        Dispatchers.Web.dispatch_web_parse(arguments)

      # Cognitive operations
      "think" ->
        Dispatchers.Cognitive.dispatch_think(arguments)

      "cognitive" ->
        Dispatchers.Cognitive.dispatch(arguments)

      # Knowledge graph operations
      "knowledge" ->
        Dispatchers.Knowledge.dispatch(arguments)

      "graph" ->
        # DEPRECATED: Redirect to unified knowledge tool
        Logger.warning(
          "[DEPRECATED] 'graph' tool is deprecated. Use 'knowledge' tool instead with same operations."
        )

        Dispatchers.Knowledge.dispatch(arguments)

      # Code analysis
      "code_symbols" ->
        Dispatchers.Code.dispatch(arguments)

      # Library documentation
      "library" ->
        Dispatchers.Library.dispatch(arguments)

      # Diagnostics
      "diagnostics" ->
        Dispatchers.Diagnostics.dispatch(arguments)

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
         "Unknown tool: #{tool_name}. Available: file, terminal, fetch, think, web_parse, search, web_extract, sonar, vision, knowledge, code_symbols, library, graph, cognitive, diagnostics, blink, browser"}
    end
  end
end
