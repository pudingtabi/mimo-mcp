defmodule Mimo.Tools.Dispatchers.DebugError do
  @moduledoc """
  Compound domain action: Error debugging assistant.

  SPEC-031 Phase 5: Chains multiple tools for comprehensive error analysis:

  1. memory search (similar errors) → Find past solutions
  2. code_symbols definition → Find where the error originates
  3. diagnostics check → Get current compiler errors

  Returns a unified debugging context with past solutions, relevant definitions,
  and current errors to help resolve issues faster.
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.{Code, Diagnostics}

  @doc """
  Dispatch debug_error operation.

  ## Options
    - message: Error message to debug (required)
    - path: Optional path to narrow diagnostics scope
    - symbol: Optional symbol name to look up definition
  """
  def dispatch(args) do
    message = args["message"]

    if is_nil(message) or message == "" do
      {:error, "message is required for debug_error"}
    else
      run_debug_analysis(message, args)
    end
  end

  defp run_debug_analysis(message, args) do
    Logger.info("[DebugError] Starting debug analysis for: #{String.slice(message, 0, 50)}...")
    start_time = System.monotonic_time(:millisecond)

    # Extract potential symbol names from error message
    extracted_symbols = extract_symbols_from_error(message)
    explicit_symbol = args["symbol"]

    symbols_to_lookup =
      if explicit_symbol, do: [explicit_symbol | extracted_symbols], else: extracted_symbols

    # Run analyses
    past_solutions = search_past_solutions(message)
    definitions = lookup_definitions(symbols_to_lookup)
    current_errors = get_current_errors(args["path"])

    duration = System.monotonic_time(:millisecond) - start_time

    # Build response
    build_response(message, past_solutions, definitions, current_errors, duration)
  end

  defp search_past_solutions(message) do
    # Search for similar errors in memory
    search_queries = [
      "error #{message}",
      "fix #{extract_error_type(message)}",
      "solution #{message}"
    ]

    results =
      search_queries
      |> Enum.flat_map(fn query ->
        case Memory.search_memories(query, limit: 5, min_similarity: 0.4) do
          memories when is_list(memories) ->
            Enum.map(memories, fn mem ->
              %{
                content: Map.get(mem, :content) || Map.get(mem, "content"),
                similarity:
                  Map.get(mem, :similarity) || Map.get(mem, :score) || Map.get(mem, "similarity") ||
                    0.0,
                category:
                  Map.get(mem, :category) || Map.get(mem, :type) || Map.get(mem, "category") ||
                    "unknown",
                created_at:
                  Map.get(mem, :inserted_at) || Map.get(mem, :created_at) ||
                    Map.get(mem, "inserted_at") || Map.get(mem, "created_at")
              }
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(& &1.content)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(10)

    %{
      found: results != [],
      count: length(results),
      solutions: results
    }
  end

  defp lookup_definitions(symbols) do
    symbols
    |> Enum.uniq()
    |> Enum.take(5)
    |> Enum.map(fn symbol ->
      case Code.dispatch(%{"operation" => "definition", "name" => symbol}) do
        {:ok, %{found: true} = result} ->
          %{
            symbol: symbol,
            found: true,
            definition: result[:definition]
          }

        {:ok, %{found: false}} ->
          %{symbol: symbol, found: false}

        {:error, _} ->
          %{symbol: symbol, found: false}
      end
    end)
  end

  defp get_current_errors(path) do
    # Run diagnostics on the specified path or entire workspace
    diag_args = %{"operation" => "check"}
    diag_args = if path, do: Map.put(diag_args, "path", path), else: diag_args

    case Diagnostics.dispatch(diag_args) do
      {:ok, result} ->
        issues = result[:issues] || result[:diagnostics] || []
        errors = Enum.filter(issues, &error?/1)

        %{
          total: length(issues),
          errors: length(errors),
          issues: Enum.take(errors, 10)
        }

      {:error, reason} ->
        %{total: 0, errors: 0, error: inspect(reason)}
    end
  end

  defp build_response(message, past_solutions, definitions, current_errors, duration) do
    # Determine if we have actionable context
    has_solutions = past_solutions[:found] || false
    has_definitions = Enum.any?(definitions, & &1[:found])
    has_errors = (current_errors[:errors] || 0) > 0

    # Build suggestion
    suggestion = build_suggestion(has_solutions, has_definitions, has_errors, past_solutions)

    {:ok,
     %{
       error_message: message,
       duration_ms: duration,
       past_solutions: past_solutions,
       definitions: definitions,
       current_errors: current_errors,
       analysis: %{
         has_past_solutions: has_solutions,
         has_definitions: has_definitions,
         has_active_errors: has_errors
       },
       suggestion: suggestion
     }}
  end

  defp build_suggestion(has_solutions, has_definitions, _has_errors, past_solutions) do
    cond do
      has_solutions ->
        top_solution = List.first(past_solutions[:solutions] || [])
        sim = if top_solution, do: Float.round((top_solution[:similarity] || 0) * 100, 1), else: 0

        "Found #{past_solutions[:count]} similar past issues (top match: #{sim}% similarity). Review past solutions above."

      has_definitions ->
        "🔍 Found relevant symbol definitions. Check the source code for potential issues."

      true ->
        "📝 No past solutions found. After fixing, store the solution in memory (category: fact, importance: ~0.8) so it persists."
    end
  end

  defp extract_symbols_from_error(message) do
    # Extract potential symbol names from error message
    patterns = [
      # Elixir module/function: Foo.Bar.baz/2
      ~r/([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)+(?:\.[a-z_][a-z0-9_]*)?)/,
      # Function name: undefined function foo/2
      ~r/(?:undefined function|is not defined:?)\s+([a-z_][a-z0-9_]*)/,
      # Variable: undefined variable foo
      ~r/(?:undefined variable|is unused)\s+([a-z_][a-z0-9_]*)/,
      # TypeScript/JS: Cannot find name 'foo'
      ~r/Cannot find (?:name|module)\s+['"]([^'"]+)['"]/,
      # Python: NameError: name 'foo' is not defined
      ~r/(?:NameError|ImportError|ModuleNotFoundError).*['"]([^'"]+)['"]/
    ]

    patterns
    |> Enum.flat_map(fn pattern ->
      case Regex.scan(pattern, message) do
        matches when is_list(matches) ->
          Enum.map(matches, fn
            [_, capture] -> capture
            [capture] -> capture
            _ -> nil
          end)

        _ ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_error_type(message) do
    # Extract the type of error for better search
    patterns = [
      {~r/(CompileError|SyntaxError|RuntimeError|ArgumentError)/i, fn m -> m end},
      {~r/(undefined function|undefined variable|is not defined)/i, fn _ -> "undefined" end},
      {~r/(Cannot find|not found)/i, fn _ -> "not found" end},
      {~r/(TypeError|ReferenceError)/i, fn m -> m end}
    ]

    Enum.find_value(patterns, message, fn {pattern, transform} ->
      case Regex.run(pattern, message) do
        [match | _] -> transform.(match)
        _ -> nil
      end
    end)
  end

  defp error?(issue) do
    severity = issue[:severity] || issue["severity"]
    severity == :error or severity == "error"
  end
end
