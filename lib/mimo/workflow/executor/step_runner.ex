defmodule Mimo.Workflow.Executor.StepRunner do
  @moduledoc """
  Step Runner for workflow execution.

  Executes individual workflow steps by invoking the appropriate Mimo tool.
  Acts as the bridge between workflow pattern steps and actual tool execution.

  ## Architecture

  Each step in a workflow pattern specifies:
  - `tool` - The Mimo tool to invoke (e.g., "memory", "file", "code")
  - `args` - Arguments to pass to the tool
  - `validation` - Optional validation for step output

  The StepRunner:
  1. Resolves the tool from the registry
  2. Executes with provided arguments
  3. Validates output if specified
  4. Returns result for context accumulation
  """
  require Logger

  alias Mimo.Workflow.ToolLog

  @type step_options :: %{
          retry_policy: map() | nil,
          validation: map() | nil
        }

  @doc """
  Run a single workflow step.

  ## Parameters
  - `tool_name` - Name of the Mimo tool to invoke
  - `args` - Tool arguments (already resolved bindings)
  - `options` - Step options (retry policy, validation)
  - `context` - Current execution context

  ## Returns
  - `{:ok, result_map}` - Step succeeded, merge result into context
  - `{:error, reason}` - Step failed
  """
  @spec run_step(String.t(), map(), step_options(), map()) :: {:ok, map()} | {:error, term()}
  def run_step(tool_name, args, options \\ %{}, context \\ %{}) do
    start_time = System.monotonic_time(:microsecond)
    session_id = context[:session_id] || generate_session_id()

    Logger.debug("Running step: #{tool_name} with args: #{inspect(args)}")

    # Log tool usage
    log_tool_usage(tool_name, args, session_id)

    # Execute the tool
    result = execute_tool(tool_name, args)

    # Emit telemetry
    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(tool_name, duration_us, result)

    # Process result
    case result do
      {:ok, output} ->
        # Validate if specified
        case validate_output(output, options[:validation]) do
          :ok ->
            # Convert output to context update
            context_update = normalize_output(tool_name, output, args)
            {:ok, Map.put(context_update, :_last_tool, tool_name)}

          {:error, validation_error} ->
            {:error, {:validation_failed, validation_error}}
        end

      {:error, reason} ->
        # Check if retryable
        if should_retry?(reason, options[:retry_policy]) do
          {:error, {:retryable, reason}}
        else
          {:error, reason}
        end
    end
  end

  # =============================================================================
  # Tool Execution
  # =============================================================================

  defp execute_tool(tool_name, args) do
    # Look up the tool in the registry
    case get_tool_handler(tool_name) do
      {:ok, handler} ->
        try do
          # Normalize args to keyword list if needed
          normalized_args = normalize_args(args)
          apply_tool_handler(handler, normalized_args)
        rescue
          e ->
            Logger.error("Tool execution error: #{Exception.message(e)}")
            {:error, {:execution_error, Exception.message(e)}}
        end

      {:error, :not_found} ->
        {:error, {:tool_not_found, tool_name}}
    end
  end

  defp get_tool_handler(tool_name) do
    # Map tool names to their handlers using Mimo.Tools.dispatch/2
    # This integrates with Mimo.Tools (SPEC-051)
    supported_tools =
      MapSet.new([
        # Core tools
        "file",
        "terminal",
        "memory",
        "code",
        "web",
        "knowledge",
        # Cognitive tools
        "reason",
        "think",
        "cognitive",
        # Composite tools (via meta)
        "meta",
        "onboard",
        "ask_mimo",
        # Procedures
        "run_procedure",
        # Legacy aliases - will map to unified tools
        "search",
        "fetch",
        "analyze_file",
        "prepare_context"
      ])

    if MapSet.member?(supported_tools, tool_name) do
      # Return a function that calls Mimo.Tools.dispatch
      handler = fn args ->
        # Handle legacy tool names by mapping to unified tools
        {mapped_tool, mapped_args} = map_legacy_tool(tool_name, args)
        Mimo.Tools.dispatch(mapped_tool, mapped_args)
      end

      {:ok, handler}
    else
      {:error, :not_found}
    end
  end

  defp map_legacy_tool("search", args) do
    {"web", Map.put(ensure_map(args), "operation", "search")}
  end

  defp map_legacy_tool("fetch", args) do
    {"web", Map.put(ensure_map(args), "operation", "fetch")}
  end

  defp map_legacy_tool("analyze_file", args) do
    {"meta", Map.put(ensure_map(args), "operation", "analyze_file")}
  end

  defp map_legacy_tool("prepare_context", args) do
    {"meta", Map.put(ensure_map(args), "operation", "prepare_context")}
  end

  defp map_legacy_tool(tool, args), do: {tool, ensure_map(args)}

  defp ensure_map(args) when is_map(args), do: args
  defp ensure_map(args) when is_list(args), do: Map.new(args)
  defp ensure_map(_), do: %{}

  defp apply_tool_handler(handler, args) when is_function(handler, 1) do
    result = handler.(args)
    normalize_result(result)
  end

  defp normalize_result({:ok, data}), do: {:ok, data}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(%{"status" => "success", "data" => data}), do: {:ok, data}
  defp normalize_result(%{"status" => "error", "error" => error}), do: {:error, error}
  defp normalize_result(%{status: "success", data: data}), do: {:ok, data}
  defp normalize_result(%{status: "error"} = err), do: {:error, err[:error] || err}
  defp normalize_result(other), do: {:ok, other}

  # =============================================================================
  # Argument Normalization
  # =============================================================================

  defp normalize_args(args) when is_map(args) do
    Enum.map(args, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    # If atom doesn't exist, convert to string keys
    ArgumentError ->
      Enum.map(args, fn {k, v} ->
        key = if is_binary(k), do: String.to_atom(k), else: k
        {key, v}
      end)
  end

  defp normalize_args(args) when is_list(args), do: args
  defp normalize_args(args), do: [args: args]

  # =============================================================================
  # Output Normalization
  # =============================================================================

  defp normalize_output(tool_name, output, args) do
    # Create a context key based on tool name or explicit output_key
    output_key = args[:output_key] || default_output_key(tool_name)

    case output do
      map when is_map(map) ->
        # If output has a "data" key, unwrap it
        data = Map.get(map, :data, Map.get(map, "data", map))
        %{output_key => data, :_raw_output => output}

      list when is_list(list) ->
        %{output_key => list}

      binary when is_binary(binary) ->
        %{output_key => binary}

      other ->
        %{output_key => other}
    end
  end

  defp default_output_key(tool_name) do
    case tool_name do
      "file" -> :file_result
      "memory" -> :memory_result
      "code" -> :code_result
      "terminal" -> :terminal_result
      "web" -> :web_result
      "knowledge" -> :knowledge_result
      "reason" -> :reasoning_result
      "meta" -> :meta_result
      _ -> String.to_atom("#{tool_name}_result")
    end
  end

  # =============================================================================
  # Validation
  # =============================================================================

  defp validate_output(_output, nil), do: :ok

  defp validate_output(output, validation) do
    required_keys = validation[:required_keys] || validation["required_keys"]
    non_empty = validation[:non_empty] || validation["non_empty"]
    success_status = validation[:success_status] || validation["success_status"]
    custom = validation[:custom] || validation["custom"]

    do_validate(output, required_keys, non_empty, success_status, custom)
  end

  # Multi-head validation dispatch
  defp do_validate(output, required_keys, _non_empty, _success_status, _custom)
       when required_keys != nil do
    missing =
      Enum.filter(required_keys, fn key ->
        not (Map.has_key?(output, key) or Map.has_key?(output, to_string(key)))
      end)

    if Enum.empty?(missing), do: :ok, else: {:error, {:missing_keys, missing}}
  end

  defp do_validate(output, _required_keys, true, _success_status, _custom) do
    if empty_result?(output), do: {:error, :empty_result}, else: :ok
  end

  defp do_validate(output, _required_keys, _non_empty, true, _custom) do
    if output[:status] == "success" or output["status"] == "success" do
      :ok
    else
      {:error, {:unexpected_status, output[:status] || output["status"]}}
    end
  end

  defp do_validate(output, _required_keys, _non_empty, _success_status, custom)
       when is_tuple(custom) and tuple_size(custom) == 2 do
    {mod, fun} = custom

    case apply(mod, fun, [output]) do
      true -> :ok
      false -> {:error, :custom_validation_failed}
      {:error, _} = err -> err
    end
  end

  defp do_validate(_output, _required_keys, _non_empty, _success_status, _custom), do: :ok

  defp empty_result?(nil), do: true
  defp empty_result?(""), do: true
  defp empty_result?([]), do: true
  defp empty_result?(map) when map == %{}, do: true
  defp empty_result?(_), do: false

  # =============================================================================
  # Retry Logic
  # =============================================================================

  defp should_retry?(_reason, nil), do: false

  defp should_retry?(reason, retry_policy) do
    retryable_errors =
      retry_policy[:retryable_errors] ||
        retry_policy["retryable_errors"] ||
        [:timeout, :connection_error, :rate_limited]

    # Check if this error type is retryable
    error_type = extract_error_type(reason)
    error_type in retryable_errors
  end

  defp extract_error_type({:timeout, _}), do: :timeout
  defp extract_error_type(:timeout), do: :timeout
  defp extract_error_type({:connection_error, _}), do: :connection_error
  defp extract_error_type({:rate_limited, _}), do: :rate_limited
  defp extract_error_type(_), do: :unknown

  # =============================================================================
  # Tool Usage Logging
  # =============================================================================

  defp log_tool_usage(tool_name, args, session_id) do
    # Async logging to avoid blocking
    Task.start(fn ->
      ToolLog.log(%{
        session_id: session_id,
        tool_name: tool_name,
        arguments: sanitize_args_for_logging(args),
        timestamp: DateTime.utc_now()
      })
    end)
  rescue
    _ -> :ok
  end

  @sensitive_keys [
    :password,
    :token,
    :secret,
    :api_key,
    :content,
    "password",
    "token",
    "secret",
    "api_key"
  ]

  defp sanitize_args_for_logging(args) do
    # Remove sensitive data from logs
    Enum.reduce(args, %{}, fn {k, v}, acc ->
      cond do
        k in @sensitive_keys -> Map.put(acc, k, "[REDACTED]")
        is_binary(v) and byte_size(v) > 1000 -> Map.put(acc, k, "[TRUNCATED]")
        true -> Map.put(acc, k, v)
      end
    end)
  end

  defp generate_session_id do
    "step_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # =============================================================================
  # Telemetry
  # =============================================================================

  defp emit_telemetry(tool_name, duration_us, result) do
    status =
      case result do
        {:ok, _} -> :success
        {:error, _} -> :error
      end

    :telemetry.execute(
      [:mimo, :workflow, :step],
      %{duration_us: duration_us},
      %{tool: tool_name, status: status}
    )
  end
end
