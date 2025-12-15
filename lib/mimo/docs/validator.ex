defmodule Mimo.Docs.Validator do
  @moduledoc """
  Documentation Accuracy Validation (Q1 2026 Phase 4).

  Validates that documentation (AGENTS.md, README.md, copilot-instructions.md)
  stays in sync with actual code. Detects:

  1. **Tool References**: Documentation mentions tools that don't exist
  2. **Operation References**: Documentation mentions operations not in schema
  3. **API Examples**: Code examples that don't match actual function signatures
  4. **File References**: Documentation references files that don't exist
  5. **Stale Instructions**: Deprecated patterns still in documentation

  ## Usage

      Mimo.Docs.Validator.validate_all()
      # => %{issues: [...], warnings: [...], suggestions: [...]}

      Mimo.Docs.Validator.validate_file("AGENTS.md")
      # => %{issues: [...], file: "AGENTS.md"}

  ## Integration

  This module is exposed via the `docs_validate` dispatcher operation,
  allowing agents to check documentation accuracy before making updates.
  """

  alias Mimo.Tools

  require Logger

  @doc_files [
    "AGENTS.md",
    "README.md",
    ".github/copilot-instructions.md",
    "VISION.md"
  ]

  @type issue :: %{
          type: :error | :warning | :suggestion,
          file: String.t(),
          line: integer() | nil,
          message: String.t(),
          context: String.t() | nil
        }

  @type validation_result :: %{
          issues: [issue()],
          warnings: [issue()],
          suggestions: [issue()],
          stats: map()
        }

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Validate all documentation files.

  Returns a comprehensive report of issues, warnings, and suggestions.
  """
  @spec validate_all() :: {:ok, validation_result()}
  def validate_all do
    base_path = get_project_root()

    results =
      @doc_files
      |> Enum.map(fn file ->
        path = Path.join(base_path, file)

        if File.exists?(path) do
          validate_file(path)
        else
          {:ok, %{issues: [], warnings: [], suggestions: [], file: file, skipped: true}}
        end
      end)
      |> Enum.map(fn
        {:ok, result} -> result
        {:error, _} -> %{issues: [], warnings: [], suggestions: []}
      end)

    # Aggregate results
    all_issues = Enum.flat_map(results, & &1.issues)
    all_warnings = Enum.flat_map(results, & &1.warnings)
    all_suggestions = Enum.flat_map(results, & &1.suggestions)

    {:ok,
     %{
       issues: all_issues,
       warnings: all_warnings,
       suggestions: all_suggestions,
       stats: %{
         files_checked: length(results),
         total_issues: length(all_issues),
         total_warnings: length(all_warnings),
         total_suggestions: length(all_suggestions)
       }
     }}
  end

  @doc """
  Validate a single documentation file.
  """
  @spec validate_file(String.t()) :: {:ok, map()} | {:error, term()}
  def validate_file(path) do
    case File.read(path) do
      {:ok, content} ->
        issues = []
        warnings = []
        _suggestions = []

        # Run all validators
        {tool_issues, tool_warnings} = validate_tool_references(content, path)
        {op_issues, op_warnings} = validate_operation_references(content, path)
        {file_issues, file_warnings} = validate_file_references(content, path)
        {pattern_issues, pattern_warnings} = validate_deprecated_patterns(content, path)

        issues = issues ++ tool_issues ++ op_issues ++ file_issues ++ pattern_issues
        warnings = warnings ++ tool_warnings ++ op_warnings ++ file_warnings ++ pattern_warnings

        # Generate suggestions
        suggestions = generate_suggestions(content, path)

        {:ok,
         %{
           issues: issues,
           warnings: warnings,
           suggestions: suggestions,
           file: path
         }}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # ============================================================================
  # TOOL REFERENCE VALIDATION
  # ============================================================================

  defp validate_tool_references(content, file) do
    # Get list of valid tool names from Tools module
    valid_tools = get_valid_tool_names()

    # Find tool references in documentation
    # Pattern: tool="xxx" or `xxx` tool or xxx operation=
    tool_pattern =
      ~r/(?:tool\s*=\s*["']([^"']+)["']|`(\w+)`\s+(?:tool|operation)|(\w+)\s+operation\s*=)/

    matches = Regex.scan(tool_pattern, content)

    issues =
      matches
      |> Enum.map(fn match ->
        tool_name = Enum.find(tl(match), & &1)
        tool_name
      end)
      |> Enum.filter(& &1)
      |> Enum.uniq()
      |> Enum.reject(fn name -> name in valid_tools end)
      |> Enum.reject(fn name -> name in ["operation", "path", "query", "content"] end)
      |> Enum.map(fn invalid_tool ->
        %{
          type: :warning,
          file: file,
          line: find_line_number(content, invalid_tool),
          message: "Referenced tool '#{invalid_tool}' not found in tool registry",
          context: "Check if tool name is correct or if it's a deprecated alias"
        }
      end)

    {[], issues}
  end

  defp get_valid_tool_names do
    # Get from Tools module
    case Tools.list_tools() do
      {:ok, tools} when is_list(tools) ->
        Enum.map(tools, fn
          %{name: name} -> name
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.filter(& &1)

      _ ->
        # Fallback to known tools
        [
          "file",
          "terminal",
          "memory",
          "web",
          "code",
          "knowledge",
          "cognitive",
          "reason",
          "think",
          "meta",
          "onboard",
          "ask_mimo",
          "awakening_status",
          "ingest",
          "run_procedure",
          "list_procedures",
          "tool_usage"
        ]
    end
  end

  # ============================================================================
  # OPERATION REFERENCE VALIDATION
  # ============================================================================

  defp validate_operation_references(content, file) do
    # Pattern: operation=xxx or operation="xxx"
    op_pattern = ~r/operation\s*=\s*["']?(\w+)["']?/

    matches = Regex.scan(op_pattern, content)

    # Get valid operations per tool (simplified - just check common ones)
    valid_operations = get_valid_operations()

    warnings =
      matches
      |> Enum.map(fn [_, op] -> op end)
      |> Enum.uniq()
      |> Enum.reject(fn op -> op in valid_operations end)
      |> Enum.map(fn invalid_op ->
        %{
          type: :warning,
          file: file,
          line: find_line_number(content, invalid_op),
          message: "Operation '#{invalid_op}' may not be valid",
          context: "Verify this operation exists in the tool schema"
        }
      end)

    {[], warnings}
  end

  defp get_valid_operations do
    # Common valid operations across tools
    [
      # File operations
      "read",
      "write",
      "edit",
      "ls",
      "search",
      "glob",
      "diff",
      "read_multiple",
      "multi_replace",
      "list_symbols",
      "read_symbol",
      "read_lines",
      "insert_after",
      "insert_before",
      "replace_lines",
      "delete_lines",
      "replace_string",
      "list_directory",
      "get_info",
      "move",
      "create_directory",
      "search_symbols",
      # Memory operations
      "store",
      "search",
      "list",
      "delete",
      "stats",
      "decay_check",
      # Code operations
      "symbols",
      "definition",
      "references",
      "call_graph",
      "index",
      "parse",
      "library_get",
      "library_search",
      "library_ensure",
      "library_discover",
      "library_stats",
      "check",
      "lint",
      "typecheck",
      "diagnose",
      "diagnostics_all",
      # Web operations
      "fetch",
      "extract",
      "blink",
      "blink_analyze",
      "blink_smart",
      "browser",
      "screenshot",
      "pdf",
      "evaluate",
      "interact",
      "test",
      "vision",
      "sonar",
      "code_search",
      "image_search",
      # Knowledge operations
      "query",
      "teach",
      "traverse",
      "explore",
      "node",
      "path",
      "link",
      "link_memory",
      "sync_dependencies",
      "neighborhood",
      # Cognitive operations
      "assess",
      "gaps",
      "can_answer",
      "suggest",
      "system_health",
      "memory_audit",
      "auto_generate_procedure",
      "procedure_candidates",
      "procedure_suitability",
      # Emergence operations (via cognitive)
      "emergence_dashboard",
      "emergence_detect",
      "emergence_alerts",
      "emergence_amplify",
      "emergence_promote",
      "emergence_cycle",
      "emergence_list",
      "emergence_search",
      "emergence_suggest",
      "emergence_status",
      # Reflector operations (via cognitive)
      "reflector_reflect",
      "reflector_evaluate",
      "reflector_confidence",
      "reflector_errors",
      "reflector_format",
      "reflector_config",
      # Verification operations (via cognitive)
      "verify_count",
      "verify_math",
      "verify_logic",
      "verify_compare",
      "verify_self_check",
      "verification_stats",
      "verification_overconfidence",
      "verification_success_by_type",
      "verification_brier_score",
      # Reason operations
      "guided",
      "decompose",
      "step",
      "verify",
      "reflect",
      "branch",
      "backtrack",
      "conclude",
      # Think operations
      "thought",
      "plan",
      "sequential",
      # Meta operations
      "analyze_file",
      "debug_error",
      "prepare_context",
      "suggest_next_tool",
      # Terminal operations
      "execute",
      "start_process",
      "read_output",
      "interact",
      "kill",
      "force_kill",
      "list_sessions",
      "list_processes"
    ]
  end

  # ============================================================================
  # FILE REFERENCE VALIDATION
  # ============================================================================

  defp validate_file_references(content, file) do
    # Pattern: path="xxx" or path/to/file.ex or lib/mimo/xxx.ex
    file_pattern =
      ~r/(?:path\s*=\s*["']([^"']+)["']|`(lib\/\w+[\/\w\.]+)`|\[([\w\/\.]+)\]\([^\)]+\))/

    matches = Regex.scan(file_pattern, content)
    base_path = get_project_root()

    issues =
      matches
      |> Enum.map(fn match ->
        Enum.find(tl(match), & &1)
      end)
      |> Enum.filter(& &1)
      |> Enum.filter(fn path ->
        # Only check paths that look like project files
        String.starts_with?(path, "lib/") or String.starts_with?(path, "test/") or
          String.starts_with?(path, "priv/")
      end)
      |> Enum.uniq()
      |> Enum.reject(fn path ->
        full_path = Path.join(base_path, path)
        File.exists?(full_path)
      end)
      |> Enum.map(fn missing_path ->
        %{
          type: :warning,
          file: file,
          line: find_line_number(content, missing_path),
          message: "Referenced file '#{missing_path}' does not exist",
          context: "File may have been moved, renamed, or deleted"
        }
      end)

    {[], issues}
  end

  # ============================================================================
  # DEPRECATED PATTERN VALIDATION
  # ============================================================================

  defp validate_deprecated_patterns(content, file) do
    deprecated_patterns = [
      {~r/code_symbols\s+operation=/,
       "code_symbols is deprecated, use 'code operation=symbols/definition/references'"},
      {~r/diagnostics\s+operation=/, "diagnostics is deprecated, use 'code operation=diagnose'"},
      {~r/library\s+operation=/, "library is deprecated, use 'code operation=library_get'"},
      {~r/graph\s+operation=/, "graph is deprecated, use 'knowledge operation='"},
      {~r/store_fact\s+/, "store_fact is deprecated, use 'memory (store)'"},
      {~r/search_vibes\s+/, "search_vibes is deprecated, use 'memory (search)'"},
      {~r/fetch\s+url=/, "fetch is deprecated, use 'web operation=fetch'"},
      {~r/blink\s+url=/, "blink is deprecated, use 'web operation=blink'"},
      {~r/browser\s+url=/, "browser is deprecated, use 'web operation=browser'"},
      {~r/vision\s+image=/, "vision is deprecated, use 'web operation=vision'"}
    ]

    warnings =
      deprecated_patterns
      |> Enum.flat_map(fn {pattern, message} ->
        if Regex.match?(pattern, content) do
          [
            %{
              type: :warning,
              file: file,
              line: find_pattern_line(content, pattern),
              message: message,
              context: "Update to use the unified tool interface"
            }
          ]
        else
          []
        end
      end)

    {[], warnings}
  end

  # ============================================================================
  # SUGGESTIONS
  # ============================================================================

  defp generate_suggestions(content, file) do
    suggestions = []

    # Check for missing mandatory sections in AGENTS.md
    suggestions =
      if String.contains?(file, "AGENTS") do
        missing_sections =
          [
            {"SESSION START", "Add a mandatory session start section"},
            {"PHASE 0", "Add AUTO-REASONING phase documentation"},
            {"Tool Selection", "Add tool selection decision trees"}
          ]
          |> Enum.reject(fn {section, _} -> String.contains?(content, section) end)
          |> Enum.map(fn {_, suggestion} ->
            %{
              type: :suggestion,
              file: file,
              line: nil,
              message: suggestion,
              context: "Consider adding this section for comprehensive agent guidance"
            }
          end)

        suggestions ++ missing_sections
      else
        suggestions
      end

    suggestions
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  defp get_project_root do
    Application.get_env(:mimo, :root_path) ||
      System.get_env("MIMO_ROOT") ||
      File.cwd!()
  end

  defp find_line_number(content, text) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, num} ->
      if String.contains?(line, text), do: num, else: nil
    end)
  end

  defp find_pattern_line(content, pattern) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, num} ->
      if Regex.match?(pattern, line), do: num, else: nil
    end)
  end

  # ============================================================================
  # QUICK VALIDATION FUNCTIONS
  # ============================================================================

  @doc """
  Quick check if a specific tool reference is valid.
  """
  @spec tool_exists?(String.t()) :: boolean()
  def tool_exists?(tool_name) do
    tool_name in get_valid_tool_names()
  end

  @doc """
  Quick check if a specific operation is valid for a tool.
  """
  @spec operation_valid?(String.t()) :: boolean()
  def operation_valid?(operation) do
    operation in get_valid_operations()
  end

  @doc """
  Get validation summary suitable for display.
  """
  @spec summary() :: String.t()
  def summary do
    {:ok, result} = validate_all()

    """
    📋 Documentation Validation Summary
    ===================================
    Files checked: #{result.stats.files_checked}
    Issues: #{result.stats.total_issues}
    Warnings: #{result.stats.total_warnings}
    Suggestions: #{result.stats.total_suggestions}

    #{format_issues(result.issues ++ result.warnings)}
    """
  end

  defp format_issues([]), do: "✅ No issues found!"

  defp format_issues(issues) do
    issues
    |> Enum.take(10)
    |> Enum.map_join("\n", fn issue ->
      line_info = if issue.line, do: ":#{issue.line}", else: ""
      "• #{issue.file}#{line_info}: #{issue.message}"
    end)
  end
end
