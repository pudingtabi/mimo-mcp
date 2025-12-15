defmodule Mimo.RequestInterceptor do
  @moduledoc """
  Intelligent request interceptor that analyzes tool requests and suggests
  cognitive enhancements. Tracks session state to detect debugging chains
  and recommend appropriate cognitive tools.

  ## Key Functions

  - `analyze_and_enrich/2` - Analyzes requests and may enrich with context
  - `record_error/2` - Records errors for debugging chain detection
  - `enrich_result/3` - Enriches successful results with relevant context
  - `reset_session/0` - Resets session state for testing
  """

  require Logger

  # Process dictionary keys for session state
  @session_errors_key :mimo_session_errors
  @session_tools_key :mimo_session_tools

  @doc """
  Analyzes a tool request and determines if cognitive enhancement is needed.

  Returns one of:
  - `{:enriched, context, metadata}` - Request enriched with cognitive context
  - `{:suggest, tool, query, reason}` - Suggestion to use a cognitive tool
  - `{:continue, nil}` - Normal execution, no enhancement needed
  """
  @spec analyze_and_enrich(String.t(), map()) ::
          {:enriched, map(), map()}
          | {:suggest, String.t(), String.t(), String.t()}
          | {:continue, nil}
  def analyze_and_enrich(tool_name, arguments) do
    # Track tool usage in session
    track_tool_usage(tool_name)

    # Check for debugging chains (multiple errors in sequence)
    errors = Process.get(@session_errors_key, [])

    cond do
      # If we have multiple recent errors, suggest debugging tools
      length(errors) >= 3 ->
        {:suggest, "reason", build_debug_query(errors),
         "Detected debugging chain with #{length(errors)} errors"}

      # Check if this is a file read that could benefit from memory context
      tool_name == "file" and get_in(arguments, ["operation"]) == "read" ->
        case get_memory_context(arguments) do
          {:ok, context} when map_size(context) > 0 ->
            {:enriched, context, %{source: :memory, tool: tool_name}}

          _ ->
            {:continue, nil}
        end

      # Check if this is a terminal command that could benefit from past error context
      tool_name == "terminal" ->
        case get_error_context(arguments) do
          {:ok, context} when map_size(context) > 0 ->
            {:enriched, context, %{source: :error_history, tool: tool_name}}

          _ ->
            {:continue, nil}
        end

      true ->
        {:continue, nil}
    end
  rescue
    error ->
      Logger.warning("[RequestInterceptor] analyze_and_enrich failed: #{inspect(error)}")
      {:continue, nil}
  end

  @doc """
  Records an error for debugging chain detection.

  The error_message can be any term - it will be safely converted to a string.
  This function is designed to never raise an exception.
  """
  @spec record_error(String.t(), term()) :: :ok
  def record_error(tool_name, error_message) do
    # Safely convert error_message to string
    message_str = safe_to_string(error_message)

    error_record = %{
      tool: tool_name,
      message: message_str,
      timestamp: System.system_time(:millisecond)
    }

    errors = Process.get(@session_errors_key, [])
    # Keep last 10 errors
    updated_errors = Enum.take([error_record | errors], 10)
    Process.put(@session_errors_key, updated_errors)

    Logger.info(
      "[RequestInterceptor] Recorded error for #{tool_name}: #{String.slice(message_str, 0, 100)}"
    )

    :ok
  rescue
    error ->
      # Log but never crash - this is a diagnostic function
      Logger.warning("[RequestInterceptor] record_error failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Enriches a tool result with relevant memory/knowledge context.

  Returns:
  - `{:enriched, enriched_result}` - Result enriched with context
  - `{:ok, original_result}` - No enrichment available
  """
  @spec enrich_result(String.t(), map(), term()) ::
          {:enriched, map()} | {:ok, term()}
  def enrich_result(tool_name, arguments, result) do
    case get_result_context(tool_name, arguments, result) do
      {:ok, context} when is_map(context) and map_size(context) > 0 ->
        enriched =
          case result do
            %{} = map -> Map.put(map, :_mimo_context, context)
            _ -> result
          end

        {:enriched, enriched}

      _ ->
        {:ok, result}
    end
  rescue
    error ->
      Logger.warning("[RequestInterceptor] enrich_result failed: #{inspect(error)}")
      {:ok, result}
  end

  @doc """
  Resets session state. Useful for testing.
  """
  @spec reset_session() :: :ok
  def reset_session do
    Process.delete(@session_errors_key)
    Process.delete(@session_tools_key)
    :ok
  end

  # Private helpers

  # Safely converts any term to a string, handling Protocol.UndefinedError
  defp safe_to_string(value) when is_binary(value), do: value

  defp safe_to_string(value) do
    # Check if String.Chars protocol is implemented for this value
    if String.Chars.impl_for(value) do
      to_string(value)
    else
      inspect(value)
    end
  rescue
    # Fallback if anything goes wrong
    _ -> inspect(value)
  end

  defp track_tool_usage(tool_name) do
    tools = Process.get(@session_tools_key, [])
    updated = Enum.take([tool_name | tools], 20)
    Process.put(@session_tools_key, updated)
  end

  defp build_debug_query(errors) do
    error_summary =
      errors
      |> Enum.take(3)
      |> Enum.map_join("; ", fn e -> "#{e.tool}: #{String.slice(e.message, 0, 50)}" end)

    "Debug session with errors: #{error_summary}"
  end

  defp get_memory_context(arguments) do
    # Try to get relevant memory context for file operations
    path = get_in(arguments, ["path"]) || ""

    if String.length(path) > 0 do
      # Search for memories related to this file
      case search_memories(path) do
        {:ok, memories} when is_list(memories) and length(memories) > 0 ->
          {:ok, %{memories: Enum.take(memories, 3), source: "memory"}}

        _ ->
          {:ok, %{}}
      end
    else
      {:ok, %{}}
    end
  rescue
    _ -> {:ok, %{}}
  end

  defp get_error_context(_arguments) do
    # Provide context from recent errors for terminal commands
    errors = Process.get(@session_errors_key, [])

    if length(errors) > 0 do
      {:ok, %{recent_errors: Enum.take(errors, 3)}}
    else
      {:ok, %{}}
    end
  rescue
    _ -> {:ok, %{}}
  end

  defp get_result_context(tool_name, _arguments, _result) do
    # Check if there's relevant context to add to this result
    errors = Process.get(@session_errors_key, [])
    tools = Process.get(@session_tools_key, [])

    context = %{}

    context =
      if length(errors) > 0 do
        Map.put(context, :recent_errors, length(errors))
      else
        context
      end

    context =
      if length(tools) > 3 do
        Map.put(context, :session_depth, length(tools))
      else
        context
      end

    # Add suggestion if we detect patterns
    context =
      if should_suggest_cognitive_tool?(tool_name, errors, tools) do
        Map.put(context, :suggestion, "💡 Consider using cognitive tools for this task")
      else
        context
      end

    {:ok, context}
  rescue
    _ -> {:ok, %{}}
  end

  defp should_suggest_cognitive_tool?(_tool_name, errors, tools) do
    # Suggest cognitive tools if:
    # 1. Multiple errors in session
    # 2. Deep tool chain without memory/knowledge usage
    # 3. Repeated file reads (could use memory)

    cond do
      length(errors) >= 2 ->
        true

      length(tools) >= 5 and not Enum.any?(tools, &cognitive_tool?/1) ->
        true

      count_occurrences(tools, "file") >= 3 ->
        true

      true ->
        false
    end
  end

  defp cognitive_tool?(tool_name) do
    tool_name in ["memory", "ask_mimo", "knowledge", "reason", "cognitive", "prepare_context"]
  end

  defp count_occurrences(list, item) do
    Enum.count(list, &(&1 == item))
  end

  defp search_memories(query) do
    # Try to search memories if the Brain module is available
    if Code.ensure_loaded?(Mimo.Brain) and function_exported?(Mimo.Brain, :search, 2) do
      case apply(Mimo.Brain, :search, [query, [limit: 3]]) do
        {:ok, results} -> {:ok, results}
        _ -> {:ok, []}
      end
    else
      {:ok, []}
    end
  rescue
    _ -> {:ok, []}
  end
end
