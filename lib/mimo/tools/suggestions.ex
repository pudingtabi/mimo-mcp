defmodule Mimo.Tools.Suggestions do
  @moduledoc """
  Cross-tool suggestions for SPEC-031 Phase 2 + SPEC-040 v1.2 Behavioral Reinforcement.

  Adds contextual tips to tool responses guiding users toward more appropriate
  tools for their use case. Now includes active behavioral reinforcement to
  counter factory LLM bias and encourage the mimo-cognitive workflow.

  ## Suggestion Rules

  | When Tool Returns | Suggest |
  |-------------------|---------|
  | `file operation=search` for code patterns | code_symbols operation=definition |
  | `file operation=read` on code file | code_symbols operation=symbols |
  | `memory operation=search` | knowledge operation=query |
  | `terminal` error output | diagnostics operation=all |
  | Any file op in unindexed project | onboard path='.' |

  ## SPEC-040 v1.2: Behavioral Reinforcement

  | Pattern Detected | Reinforcement |
  |------------------|---------------|
  | 3+ consecutive file/terminal without context | Warning to use memory/ask_mimo |
  | Low context ratio (<20%) after 10+ calls | Suggestion to improve balance |
  | After file edit or terminal with errors | Prompt to store insights |
  """

  alias Mimo.Awakening.ContextInjector

  @code_extensions ~w(.ex .exs .py .js .ts .tsx .rs .go .rb .java .c .cpp .h .hpp)
  @code_search_patterns ~w(def defp fn function class module struct impl trait interface)

  @doc """
  Add a suggestion to a response map based on tool context.
  Returns the response with a :suggestion key added if applicable.
  Now includes SPEC-040 v1.2 behavioral reinforcement.
  """
  @spec add_suggestion(map(), String.t(), map()) :: map()
  def add_suggestion(response, tool_name, args) when is_map(response) do
    # Skip if already has a suggestion
    if Map.has_key?(response, :suggestion) do
      response
    else
      # First check for behavioral reinforcement (SPEC-040 v1.2)
      case get_behavioral_suggestion(tool_name, args) do
        nil ->
          # Fall back to standard tool suggestions
          case generate_suggestion(tool_name, args, response) do
            nil -> response
            suggestion -> Map.put(response, :suggestion, suggestion)
          end

        behavioral_suggestion ->
          Map.put(response, :suggestion, behavioral_suggestion)
      end
    end
  end

  def add_suggestion(response, _tool_name, _args), do: response

  @doc """
  Enrich an {:ok, data} tuple with a suggestion.
  """
  @spec maybe_add_suggestion({:ok, map()} | {:error, term()}, String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def maybe_add_suggestion({:ok, data}, tool_name, args) when is_map(data) do
    {:ok, add_suggestion(data, tool_name, args)}
  end

  def maybe_add_suggestion(other, _tool_name, _args), do: other

  # ==========================================================================
  # SPEC-040 v1.2: BEHAVIORAL REINFORCEMENT
  # ==========================================================================

  @doc """
  Get behavioral reinforcement suggestion based on current session patterns.
  This actively counters factory LLM bias by reminding about the mimo-cognitive workflow.
  """
  @spec get_behavioral_suggestion(String.t(), map()) :: String.t() | nil
  def get_behavioral_suggestion(tool_name, _args) do
    case get_session_id() do
      nil -> nil
      session_id -> ContextInjector.generate_reinforcement_suggestion(session_id, tool_name)
    end
  end

  defp get_session_id do
    # Try to get session ID from process dictionary
    Process.get(:mimo_session_id)
  end

  # ==========================================================================
  # SUGGESTION GENERATORS
  # ==========================================================================

  defp generate_suggestion(tool_name, args, response)

  # File search for code patterns → code_symbols
  defp generate_suggestion("file", %{"operation" => "search", "pattern" => pattern}, _response)
       when is_binary(pattern) do
    if looks_like_code_search?(pattern) do
      "💡 For precise symbol lookup, try `code_symbols operation=definition name=\"#{extract_symbol_name(pattern)}\"`"
    else
      nil
    end
  end

  # File read on code file → code_symbols symbols
  defp generate_suggestion("file", %{"operation" => "read", "path" => path}, _response)
       when is_binary(path) do
    if code_file?(path) do
      "💡 List all functions/classes with `code_symbols operation=symbols path=\"#{path}\"`"
    else
      nil
    end
  end

  # Memory search → knowledge query
  defp generate_suggestion("memory", %{"operation" => "search"}, _response) do
    "💡 For entity relationships, also check `knowledge operation=query`"
  end

  # Terminal with error output → diagnostics
  defp generate_suggestion("terminal", _args, %{output: output}) when is_binary(output) do
    if has_error_indicators?(output) do
      "💡 For structured error analysis, try `diagnostics operation=all`"
    else
      nil
    end
  end

  defp generate_suggestion("terminal", _args, %{"output" => output}) when is_binary(output) do
    if has_error_indicators?(output) do
      "💡 For structured error analysis, try `diagnostics operation=all`"
    else
      nil
    end
  end

  # Catch-all
  defp generate_suggestion(_tool_name, _args, _response), do: nil

  # ==========================================================================
  # HELPER FUNCTIONS
  # ==========================================================================

  defp looks_like_code_search?(pattern) do
    pattern_lower = String.downcase(pattern)

    # Check if pattern looks like it's searching for code constructs
    # Check for camelCase or PascalCase patterns (function/class names)
    # Check for snake_case function names
    # Check for module paths
    Enum.any?(@code_search_patterns, fn keyword ->
      String.contains?(pattern_lower, keyword)
    end) or
      Regex.match?(~r/[a-z][A-Z]/, pattern) or
      (Regex.match?(~r/^[a-z_]+$/, pattern) and String.length(pattern) > 3) or
      String.contains?(pattern, ".")
  end

  defp extract_symbol_name(pattern) do
    # Extract the most likely symbol name from a search pattern
    pattern
    |> String.replace(~r/^(def|defp|fn|function|class|module)\s+/, "")
    |> String.split(~r/[\s\(\[\{]/, parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp code_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @code_extensions
  end

  defp has_error_indicators?(output) do
    output_lower = String.downcase(output)

    String.contains?(output_lower, [
      "error",
      "failed",
      "failure",
      "exception",
      "traceback",
      "undefined",
      "not found",
      "cannot find",
      "no such file",
      "syntax error",
      "compile error",
      "type error",
      "reference error"
    ])
  end
end
