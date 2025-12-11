defmodule Mimo.Knowledge.InjectionMiddleware do
  @moduledoc """
  SPEC-065: Proactive Knowledge Injection Engine - Middleware

  Wraps tool dispatch with knowledge injection capabilities.

  This middleware:
  1. Injects relevant knowledge BEFORE tool execution
  2. Checks for contradictions in tool results
  3. Returns enriched responses with injection metadata

  Integration point for SPEC-065 into the Mimo tool dispatch pipeline.
  """

  alias Mimo.Knowledge.{PreToolInjector, ContradictionDetector}

  require Logger

  @type dispatch_fn :: (-> {:ok, any()} | {:error, any()})
  @type injection :: map() | nil
  @type enriched_result :: {any(), injection()}

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Wrap a tool dispatch with knowledge injection.

  Returns a tuple of {result, injection} where injection may be nil.

  ## Example

      InjectionMiddleware.wrap_dispatch("file", %{"path" => "auth.ex"}, fn ->
        dispatch_file_read(args)
      end)
      # => {{:ok, %{content: "..."}}, %{type: :proactive_injection, memories: [...]}}
  """
  @spec wrap_dispatch(String.t(), map(), dispatch_fn()) :: enriched_result()
  def wrap_dispatch(tool_name, args, dispatch_fn) do
    # 1. Pre-tool injection (only for eligible tools)
    injection =
      if PreToolInjector.should_inject?(tool_name) do
        try do
          PreToolInjector.inject(tool_name, args)
        rescue
          e ->
            Logger.warning("[InjectionMiddleware] Pre-tool injection error: #{inspect(e)}")
            nil
        end
      else
        nil
      end

    # 2. Execute the actual tool dispatch
    result = dispatch_fn.()

    # 3. Post-execution: check for contradictions in result
    result_with_checks = check_result_contradictions(result, injection)

    # 4. Return enriched result with injection metadata
    {result_with_checks, injection}
  end

  @doc """
  Simple wrapper that just returns the result without injection.
  Useful for tools that shouldn't have injection overhead.
  """
  @spec passthrough(dispatch_fn()) :: enriched_result()
  def passthrough(dispatch_fn) do
    {dispatch_fn.(), nil}
  end

  @doc """
  Extract just the result from an enriched result tuple.
  """
  @spec unwrap(enriched_result()) :: any()
  def unwrap({result, _injection}), do: result

  @doc """
  Check if an enriched result has injection data.
  """
  @spec has_injection?(enriched_result()) :: boolean()
  def has_injection?({_result, nil}), do: false
  def has_injection?({_result, injection}) when is_map(injection), do: true
  def has_injection?(_), do: false

  # ============================================================================
  # CONTRADICTION CHECKING
  # ============================================================================

  defp check_result_contradictions({:ok, data}, injection) when is_map(data) do
    # Check if result content contradicts stored knowledge
    case extract_checkable_content(data) do
      nil ->
        {:ok, data}

      content ->
        case ContradictionDetector.check(content) do
          {:ok, []} ->
            {:ok, data}

          {:ok, contradictions} ->
            # Merge contradictions into result
            enhanced_data = Map.put(data, :_mimo_contradictions, contradictions)

            # Also add to injection if present
            if injection do
              Logger.info(
                "[InjectionMiddleware] Found #{length(contradictions)} contradictions in result"
              )
            end

            {:ok, enhanced_data}
        end
    end
  end

  defp check_result_contradictions(result, _injection), do: result

  defp extract_checkable_content(%{content: content}) when is_binary(content), do: content
  defp extract_checkable_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_checkable_content(%{data: %{content: content}}) when is_binary(content), do: content
  defp extract_checkable_content(_), do: nil

  # ============================================================================
  # INJECTION FORMATTING
  # ============================================================================

  @doc """
  Format injection data for inclusion in MCP response.

  This adds the injection as metadata that the AI can see.
  """
  @spec format_for_response(any(), injection()) :: map()
  def format_for_response(result, nil) do
    format_result(result)
  end

  def format_for_response(result, injection) when is_map(injection) do
    base = format_result(result)

    # Add injection as special Mimo field
    Map.put(base, :_mimo_injection, %{
      memories: Map.get(injection, :memories, []),
      source: Map.get(injection, :source, "SPEC-065"),
      relevance_scores: Map.get(injection, :relevance_scores, [])
    })
  end

  defp format_result({:ok, data}) when is_map(data), do: data
  defp format_result({:ok, data}), do: %{result: data}
  defp format_result({:error, reason}), do: %{error: reason}
  defp format_result(other), do: %{result: other}

  # ============================================================================
  # STATISTICS
  # ============================================================================

  @doc """
  Get injection statistics (placeholder for future metrics).
  """
  @spec stats() :: map()
  def stats do
    %{
      spec: "SPEC-065",
      status: :active,
      description: "Proactive Knowledge Injection Engine",
      components: [
        "PreToolInjector",
        "ContradictionDetector",
        "InjectionMiddleware"
      ]
    }
  end
end
