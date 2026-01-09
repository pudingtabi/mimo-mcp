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

  alias Mimo.TaskHelper
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

      if File.exists?(abs_path) do
        run_analysis(abs_path, args)
      else
        {:error, "File not found: #{abs_path}"}
      end
    end
  end

  defp run_analysis(path, args) do
    Logger.info("[AnalyzeFile] Starting unified analysis for: #{path}")
    start_time = System.monotonic_time(:millisecond)

    # Run all analyses in parallel using Task.async with sandbox allowance
    tasks = [
      {:file_info,
       TaskHelper.async_with_callers(fn -> {:file_info, get_file_info(path, args)} end)},
      {:symbols, TaskHelper.async_with_callers(fn -> {:symbols, get_symbols(path)} end)},
      {:diagnostics,
       TaskHelper.async_with_callers(fn -> {:diagnostics, get_diagnostics(path)} end)},
      {:knowledge,
       TaskHelper.async_with_callers(fn -> {:knowledge, get_knowledge_context(path)} end)}
    ]

    # Collect results with timeout - use yield_many for graceful timeout handling
    results =
      tasks
      |> Enum.map(fn {_name, task} -> task end)
      |> Task.yield_many(15_000)
      |> Enum.zip(tasks)
      |> Enum.map(fn
        {{_task, {:ok, {key, value}}}, _} ->
          {key, value}

        {{task, nil}, {name, _}} ->
          # Task timed out - shutdown and return fallback
          Task.shutdown(task, :brutal_kill)
          Logger.warning("[AnalyzeFile] #{name} task timed out")
          {name, %{error: "timeout", message: "Analysis timed out after 15s"}}

        {{_task, {:exit, reason}}, {name, _}} ->
          Logger.warning("[AnalyzeFile] #{name} task crashed: #{inspect(reason)}")
          {name, %{error: "crashed", message: inspect(reason)}}
      end)
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
    # Diagnostics.dispatch always returns {:ok, result}
    {:ok, result} = Diagnostics.dispatch(%{"operation" => "all", "path" => path})

    issues = result[:issues] || result[:diagnostics] || []
    errors = Enum.filter(issues, &(&1[:severity] == :error or &1["severity"] == "error"))
    warnings = Enum.filter(issues, &(&1[:severity] == :warning or &1["severity"] == "warning"))

    %{
      total: length(issues),
      errors: length(errors),
      warnings: length(warnings),
      issues: Enum.take(issues, 10)
    }
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
        suggestions ++ ["No symbols indexed. Run `onboard` to index codebase."]
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
      if knowledge[:has_context] do
        suggestions
      else
        suggestions ++
          ["📚 Use `knowledge operation=link path=\".\"` to connect to knowledge graph."]
      end

    case suggestions do
      [] -> "✨ File looks good! All systems indexed."
      _ -> Enum.join(suggestions, "\n")
    end
  end

  defp detect_file_type(path) do
    path |> Path.extname() |> String.downcase() |> ext_to_type()
  end

  defp ext_to_type(".ex"), do: "elixir"
  defp ext_to_type(".exs"), do: "elixir_script"
  defp ext_to_type(".ts"), do: "typescript"
  defp ext_to_type(".tsx"), do: "typescript_react"
  defp ext_to_type(".js"), do: "javascript"
  defp ext_to_type(".jsx"), do: "javascript_react"
  defp ext_to_type(".py"), do: "python"
  defp ext_to_type(".rs"), do: "rust"
  defp ext_to_type(".go"), do: "go"
  defp ext_to_type(".md"), do: "markdown"
  defp ext_to_type(".json"), do: "json"
  defp ext_to_type(".yaml"), do: "yaml"
  defp ext_to_type(".yml"), do: "yaml"
  defp ext_to_type(_), do: "unknown"

  # Only called with list argument (guard ensures this)
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

  # Only called with list argument (guard ensures this)
  defp group_symbols_by_kind(symbols) when is_list(symbols) do
    symbols
    |> Enum.group_by(&(&1[:kind] || &1["kind"] || "unknown"))
    |> Enum.map(fn {kind, items} -> {kind, length(items)} end)
    |> Enum.into(%{})
  end
end
