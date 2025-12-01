defmodule Mimo.Tools.Dispatchers.AnalyzeFile do
  @moduledoc """
  Compound domain action: Unified file analysis.

  SPEC-031 Phase 5: Chains multiple tools for comprehensive file analysis:

  1. file read → Get file content
  2. code_symbols symbols → Get code structure (functions, classes, modules)
  3. diagnostics all → Get compile/lint errors
  4. knowledge node → Get related knowledge graph context

  Returns a unified analysis result combining all perspectives.
  """

  require Logger

  alias Mimo.Tools.Dispatchers.{Code, Diagnostics, Knowledge}
  alias Mimo.Tools.Dispatchers.File, as: FileDispatcher

  @doc """
  Dispatch analyze_file operation.

  ## Options
    - path: File path to analyze (required)
    - include_content: Include file content in response (default: false)
    - max_content_lines: Max lines of content to include (default: 100)
  """
  def dispatch(args) do
    path = args["path"]

    if is_nil(path) or path == "" do
      {:error, "path is required for analyze_file"}
    else
      abs_path = Path.expand(path)

      unless File.exists?(abs_path) do
        {:error, "File not found: #{abs_path}"}
      else
        run_analysis(abs_path, args)
      end
    end
  end

  # ==========================================================================
  # ANALYSIS PIPELINE
  # ==========================================================================

  defp run_analysis(path, args) do
    Logger.info("[AnalyzeFile] Starting unified analysis for: #{path}")
    start_time = System.monotonic_time(:millisecond)

    # Run all analyses in parallel using Task.async
    tasks = [
      Task.async(fn -> {:file_info, get_file_info(path, args)} end),
      Task.async(fn -> {:symbols, get_symbols(path)} end),
      Task.async(fn -> {:diagnostics, get_diagnostics(path)} end),
      Task.async(fn -> {:knowledge, get_knowledge_context(path)} end)
    ]

    # Collect results with timeout
    results =
      tasks
      |> Task.await_many(15_000)
      |> Enum.into(%{})

    duration = System.monotonic_time(:millisecond) - start_time

    # Build unified response
    build_response(path, results, duration)
  end

  defp get_file_info(path, args) do
    include_content = Map.get(args, "include_content", false)
    max_lines = Map.get(args, "max_content_lines", 100)

    # Get file metadata
    info_result = FileDispatcher.dispatch(%{"operation" => "get_info", "path" => path})

    # Optionally get content
    content_result =
      if include_content do
        case FileDispatcher.dispatch(%{
               "operation" => "read_lines",
               "path" => path,
               "end_line" => max_lines
             }) do
          {:ok, data} -> data
          _ -> nil
        end
      else
        nil
      end

    case info_result do
      {:ok, info} ->
        %{
          path: path,
          exists: true,
          size: info[:size],
          modified: info[:mtime],
          type: detect_file_type(path),
          content: content_result
        }

      {:error, reason} ->
        %{path: path, exists: false, error: reason}
    end
  end

  defp get_symbols(path) do
    case Code.dispatch(%{"operation" => "symbols", "path" => path}) do
      {:ok, result} ->
        symbols = result[:symbols] || []

        %{
          count: length(symbols),
          symbols: summarize_symbols(symbols),
          by_kind: group_symbols_by_kind(symbols)
        }

      {:error, reason} ->
        %{count: 0, error: inspect(reason)}
    end
  end

  defp get_diagnostics(path) do
    case Diagnostics.dispatch(%{"operation" => "all", "path" => path}) do
      {:ok, result} ->
        issues = result[:issues] || result[:diagnostics] || []
        errors = Enum.filter(issues, &(&1[:severity] == :error or &1["severity"] == "error"))
        warnings = Enum.filter(issues, &(&1[:severity] == :warning or &1["severity"] == "warning"))

        %{
          total: length(issues),
          errors: length(errors),
          warnings: length(warnings),
          issues: Enum.take(issues, 10)
        }

      {:error, reason} ->
        %{total: 0, error: inspect(reason)}
    end
  end

  defp get_knowledge_context(path) do
    # Try to find related nodes in knowledge graph
    filename = Path.basename(path)
    dirname = Path.dirname(path) |> Path.basename()

    case Knowledge.dispatch(%{
           "operation" => "query",
           "query" => "#{filename} #{dirname}"
         }) do
      {:ok, result} ->
        %{
          has_context: result[:combined_count] > 0 or result[:count] > 0,
          semantic_store: result[:semantic_store],
          synapse_graph: result[:synapse_graph]
        }

      {:error, _} ->
        %{has_context: false}
    end
  end

  # ==========================================================================
  # RESPONSE BUILDING
  # ==========================================================================

  defp build_response(path, results, duration) do
    file_info = results[:file_info] || %{}
    symbols = results[:symbols] || %{}
    diagnostics = results[:diagnostics] || %{}
    knowledge = results[:knowledge] || %{}

    # Determine overall health
    health = assess_health(diagnostics)

    # Build suggestion based on findings
    suggestion = build_suggestion(symbols, diagnostics, knowledge)

    {:ok,
     %{
       path: path,
       duration_ms: duration,
       health: health,
       file: file_info,
       symbols: symbols,
       diagnostics: diagnostics,
       knowledge: knowledge,
       suggestion: suggestion
     }}
  end

  defp assess_health(diagnostics) do
    errors = diagnostics[:errors] || 0
    warnings = diagnostics[:warnings] || 0

    cond do
      errors > 0 -> "❌ #{errors} errors found"
      warnings > 5 -> "⚠️ #{warnings} warnings"
      warnings > 0 -> "✅ OK (#{warnings} minor warnings)"
      true -> "✅ Clean"
    end
  end

  defp build_suggestion(symbols, diagnostics, knowledge) do
    suggestions = []

    # Suggest based on symbols
    suggestions =
      if (symbols[:count] || 0) == 0 do
        suggestions ++ ["💡 No symbols indexed. Run `onboard` to index codebase."]
      else
        suggestions
      end

    # Suggest based on diagnostics
    suggestions =
      if (diagnostics[:errors] || 0) > 0 do
        suggestions ++ ["🔧 Use `debug_error message=\"...\"` to find solutions for errors."]
      else
        suggestions
      end

    # Suggest based on knowledge
    suggestions =
      if !knowledge[:has_context] do
        suggestions ++
          ["📚 Use `knowledge operation=link path=\".\"` to connect to knowledge graph."]
      else
        suggestions
      end

    case suggestions do
      [] -> "✨ File looks good! All systems indexed."
      _ -> Enum.join(suggestions, "\n")
    end
  end

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  defp detect_file_type(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".ex" -> "elixir"
      ".exs" -> "elixir_script"
      ".ts" -> "typescript"
      ".tsx" -> "typescript_react"
      ".js" -> "javascript"
      ".jsx" -> "javascript_react"
      ".py" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ".md" -> "markdown"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      _ -> "unknown"
    end
  end

  defp summarize_symbols(symbols) when is_list(symbols) do
    symbols
    |> Enum.take(20)
    |> Enum.map(fn sym ->
      %{
        name: sym[:name] || sym["name"],
        kind: sym[:kind] || sym["kind"],
        line: sym[:start_line] || sym["start_line"]
      }
    end)
  end

  defp summarize_symbols(_), do: []

  defp group_symbols_by_kind(symbols) when is_list(symbols) do
    symbols
    |> Enum.group_by(&(&1[:kind] || &1["kind"] || "unknown"))
    |> Enum.map(fn {kind, items} -> {kind, length(items)} end)
    |> Enum.into(%{})
  end

  defp group_symbols_by_kind(_), do: %{}
end
