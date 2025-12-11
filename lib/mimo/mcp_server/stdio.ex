defmodule Mimo.McpServer.Stdio do
  @moduledoc """
  Native Elixir implementation of the MCP Model Context Protocol over Stdio.
  Replaces the legacy Python bridge and Mimo.McpCli.

  SPEC-040: Awakening Protocol Integration
  - Starts a session on `initialize`
  - Injects awakening context on first `tools/call`
  - Supports `prompts/list` and `prompts/get` for awakening prompts
  """
  require Logger

  alias Mimo.TaskHelper

  # JSON-RPC Error Codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @internal_error -32_603

  # Timeout for tool execution (60 seconds)
  @tool_timeout 60_000

  @doc """
  Starts the Stdio server loop.
  This function blocks until EOF is received on stdin.
  """
  def start do
    # 1. CRITICAL: Completely silence ALL logger output to prevent protocol corruption
    # Setting level to :none is not enough - we must remove all handlers

    # Remove ALL OTP :logger handlers
    for handler_id <- :logger.get_handler_ids() do
      :logger.remove_handler(handler_id)
    end

    # Set primary config to emergency only (no output)
    :logger.set_primary_config(:level, :emergency)

    # Also set Elixir Logger level and remove console backend
    Application.put_env(:logger, :level, :none)

    # Remove Elixir Logger console backend if present
    try do
      Logger.remove_backend(:console)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # 2. Configure IO for raw binary mode with immediate flushing
    :io.setopts(:standard_io, [:binary, {:encoding, :utf8}, {:buffer, 1024}])

    # Note: No startup health check needed - defensive error handling in
    # Mimo.ToolRegistry.active_skill_tools() handles the race condition gracefully

    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        # Cleanly exit the VM when stdin closes
        System.halt(0)

      {:error, _reason} ->
        # Exit on IO error
        System.halt(0)

      line when is_binary(line) ->
        process_line(String.trim(line))
        loop()
    end
  end

  defp process_line(""), do: :ok

  defp process_line(line) do
    case Jason.decode(line) do
      {:ok, request} -> handle_request(request)
      {:error, _} -> send_error(nil, @parse_error, "Parse error")
    end
  rescue
    e -> send_error(nil, @internal_error, "Internal processing error: #{Exception.message(e)}")
  end

  # --- Request Handlers ---

  defp handle_request(%{"method" => "initialize", "id" => id} = _req) do
    # SPEC-040: Start awakening session
    session_id = generate_session_id()
    Process.put(:mimo_session_id, session_id)
    Process.put(:mimo_awakening_triggered, false)

    # Start session tracking (async)
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      Mimo.Awakening.start_session(%{
        session_id: session_id,
        user_id: "default",
        project_id: infer_project_id()
      })
    end)

    send_response(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{
        "tools" => %{"listChanged" => true},
        "prompts" => %{"listChanged" => true}
      },
      "serverInfo" => %{
        "name" => "mimo-mcp",
        "version" => "2.4.0"
      }
    })
  end

  defp handle_request(%{"method" => "notifications/initialized"}) do
    # No response required for notifications
    :ok
  end

  defp handle_request(%{"method" => "tools/list", "id" => id}) do
    # Use ToolRegistry for complete tool list (internal + core + catalog + skills)
    # Direct function call - not a GenServer message
    tools =
      try do
        Mimo.ToolRegistry.list_all_tools()
      rescue
        error ->
          # Log to stderr (logger is silenced in stdio mode)
          Mimo.Defensive.warn_stderr(
            "ToolRegistry error: #{inspect(error)} - returning empty tools list"
          )

          []
      end

    send_response(id, %{"tools" => tools})
  end

  # SPEC-040: Prompts/list handler
  defp handle_request(%{"method" => "prompts/list", "id" => id}) do
    prompts = Mimo.Awakening.PromptResource.list_prompts()
    send_response(id, %{"prompts" => prompts})
  end

  # SPEC-040: Prompts/get handler
  defp handle_request(%{"method" => "prompts/get", "params" => params, "id" => id}) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case Mimo.Awakening.PromptResource.get_prompt(name, arguments) do
      {:ok, result} ->
        send_response(id, result)

      {:error, reason} ->
        send_error(id, @internal_error, "Prompt error: #{reason}")
    end
  end

  defp handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]
    args = params["arguments"] || %{}
    start_time = System.monotonic_time(:millisecond)

    # SPEC-040: Record tool call and check for awakening trigger
    session_id = Process.get(:mimo_session_id)
    awakening_already_triggered = Process.get(:mimo_awakening_triggered, false)

    # Record the tool call (async)
    if session_id do
      Mimo.Sandbox.run_async(Mimo.Repo, fn -> Mimo.Awakening.record_tool_call(session_id) end)
    end

    # Check ToolRegistry first for both internal and external tools
    case Mimo.ToolRegistry.get_tool_owner(tool_name) do
      {:ok, {:skill, skill_name, _pid, _tool_def}} ->
        # External skill - already running (with timeout)
        execute_with_timeout(
          fn ->
            result = Mimo.Skills.Client.call_tool(skill_name, tool_name, args)
            duration = System.monotonic_time(:millisecond) - start_time
            # Auto-memory: record tool interactions
            Mimo.AutoMemory.wrap_tool_call(tool_name, args, result)
            # Passive memory: record interaction to thread (SPEC-012)
            record_interaction(tool_name, args, result, duration)
            result
          end,
          id,
          awakening_already_triggered
        )

      {:ok, {:skill_lazy, skill_name, config, _}} ->
        # External skill - lazy spawn (with timeout)
        execute_with_timeout(
          fn ->
            result = Mimo.Skills.Client.call_tool_sync(skill_name, config, tool_name, args)
            duration = System.monotonic_time(:millisecond) - start_time
            # Auto-memory: record tool interactions
            Mimo.AutoMemory.wrap_tool_call(tool_name, args, result)
            # Passive memory: record interaction to thread (SPEC-012)
            record_interaction(tool_name, args, result, duration)
            result
          end,
          id,
          awakening_already_triggered
        )

      {:ok, {:internal, _}} ->
        # Internal tool - use ToolInterface for consistency (with timeout)
        execute_with_timeout(
          fn ->
            result = Mimo.ToolInterface.execute(tool_name, args)
            duration = System.monotonic_time(:millisecond) - start_time
            # Auto-memory: record tool interactions
            Mimo.AutoMemory.wrap_tool_call(tool_name, args, result)
            # Passive memory: record interaction to thread (SPEC-012)
            record_interaction(tool_name, args, result, duration)
            result
          end,
          id,
          awakening_already_triggered
        )

      {:ok, {:mimo_core, _}} ->
        # Mimo.Tools core capabilities - use ToolInterface for consistency (with timeout)
        execute_with_timeout(
          fn ->
            result = Mimo.ToolInterface.execute(tool_name, args)
            duration = System.monotonic_time(:millisecond) - start_time
            # Auto-memory: record tool interactions
            Mimo.AutoMemory.wrap_tool_call(tool_name, args, result)
            # Passive memory: record interaction to thread (SPEC-012)
            record_interaction(tool_name, args, result, duration)
            result
          end,
          id,
          awakening_already_triggered
        )

      {:error, :not_found} ->
        available = Mimo.ToolRegistry.list_all_tools() |> Enum.map(& &1["name"])

        send_error(
          id,
          @internal_error,
          "Tool '#{tool_name}' not found. Available: #{inspect(available)}"
        )
    end
  end

  # Handle unknown methods
  defp handle_request(%{"method" => method, "id" => id}) do
    send_error(id, @method_not_found, "Method not found: #{method}")
  end

  # Handle notifications (no id) - ignore unknown ones
  defp handle_request(%{"method" => _method}) do
    :ok
  end

  defp handle_request(_invalid) do
    send_error(nil, @invalid_request, "Invalid Request")
  end

  # --- Helpers ---

  # SPEC-040: Generate a unique session ID
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # SPEC-040: Infer project ID from environment or workspace
  defp infer_project_id do
    cond do
      project = System.get_env("MIMO_PROJECT_ID") ->
        project

      root = System.get_env("MIMO_ROOT") ->
        Path.basename(root)

      true ->
        "default"
    end
  end

  # Record interaction to ThreadManager for passive memory (SPEC-012)
  defp record_interaction(tool_name, args, result, duration_ms) do
    result_summary = summarize_result(result)

    Mimo.Brain.ThreadManager.record_interaction(tool_name,
      arguments: args,
      result_summary: result_summary,
      duration_ms: duration_ms
    )
  rescue
    # Don't let recording failures affect tool execution
    _ -> :ok
  end

  # Create a brief summary of the result for storage
  defp summarize_result({:ok, result}) when is_binary(result) do
    truncate_string(result, 2000)
  end

  defp summarize_result({:ok, result}) when is_map(result) do
    result
    |> summarize_map()
    |> Jason.encode!()
    |> truncate_string(2000)
  end

  defp summarize_result({:error, reason}), do: "Error: #{inspect(reason)}"
  defp summarize_result(other), do: truncate_string(inspect(other), 2000)

  defp summarize_map(map) when is_map(map) do
    map
    # Limit keys
    |> Enum.take(10)
    |> Enum.map(fn {k, v} -> {k, summarize_value(v)} end)
    |> Map.new()
  end

  defp summarize_value(v) when is_binary(v), do: truncate_string(v, 200)
  defp summarize_value(v) when is_map(v), do: summarize_map(v)
  defp summarize_value(v) when is_list(v) and length(v) > 5, do: Enum.take(v, 5) ++ ["..."]
  defp summarize_value(v), do: v

  defp truncate_string(s, max_len) when byte_size(s) > max_len do
    String.slice(s, 0, max_len - 3) <> "..."
  end

  defp truncate_string(s, _), do: s

  # Execute a tool function with timeout protection
  # SPEC-040: Includes awakening context injection on first tool call
  defp execute_with_timeout(fun, id, awakening_already_triggered) do
    # Use supervised task if TaskSupervisor is available, otherwise fallback to unsupervised
    task = spawn_tool_task(fun)

    case Task.yield(task, @tool_timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        content = format_content(result)

        # SPEC-040: Inject awakening context on first tool call
        content_with_awakening =
          if awakening_already_triggered do
            content
          else
            Process.put(:mimo_awakening_triggered, true)
            inject_awakening_context(content)
          end

        send_response(id, %{"content" => content_with_awakening})

      {:ok, {:error, reason}} ->
        send_error(id, @internal_error, to_string(reason))

      nil ->
        send_error(id, @internal_error, "Tool execution timed out after #{@tool_timeout}ms")
    end
  rescue
    e ->
      send_error(id, @internal_error, "Tool execution error: #{Exception.message(e)}")
  end

  # Spawn a task for tool execution with fallback when TaskSupervisor is unavailable
  defp spawn_tool_task(fun) do
    if task_supervisor_available?() do
      TaskHelper.async_with_callers(fun)
    else
      # Fallback: spawn unsupervised task with $callers propagation
      caller = self()
      callers = Process.get(:"$callers", [])

      Task.async(fn ->
        Process.put(:"$callers", [caller | callers])
        fun.()
      end)
    end
  end

  # Check if Mimo.TaskSupervisor is running
  defp task_supervisor_available? do
    case Process.whereis(Mimo.TaskSupervisor) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  # SPEC-040: Inject awakening context before tool result
  defp inject_awakening_context(content) do
    session_id = Process.get(:mimo_session_id)

    case Mimo.Awakening.maybe_inject_awakening(session_id, %{}) do
      {:inject, awakening_content} ->
        # Prepend awakening as a text block
        awakening_block = %{
          "type" => "text",
          "text" => awakening_content
        }

        [awakening_block | content]

      :skip ->
        content
    end
  rescue
    # Don't let awakening failures affect tool execution
    _ -> content
  end

  defp send_response(id, result) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }

    emit_json(msg)
  end

  defp send_error(id, code, message) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }

    emit_json(msg)
  end

  defp emit_json(map) do
    # Use escape: :unicode_safe to ensure proper Unicode handling
    case Jason.encode(map, escape: :unicode_safe) do
      {:ok, json} ->
        IO.write(:stdio, json <> "\n")
        # Force flush to ensure immediate delivery
        :io.put_chars(:standard_io, [])

      {:error, _} ->
        # Fallback: sanitize the map and try again
        sanitized = sanitize_for_json(map)

        case Jason.encode(sanitized) do
          {:ok, json} ->
            IO.write(:stdio, json <> "\n")
            :io.put_chars(:standard_io, [])

          {:error, reason} ->
            # Last resort: send error
            error_json =
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => map["id"],
                "error" => %{
                  "code" => -32_603,
                  "message" => "JSON encoding failed: #{inspect(reason)}"
                }
              })

            IO.write(:stdio, error_json <> "\n")
            :io.put_chars(:standard_io, [])
        end
    end
  end

  # Sanitize data to be JSON-safe
  defp sanitize_for_json(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {sanitize_for_json(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end

  defp sanitize_for_json(data) when is_binary(data) do
    # Remove or replace invalid Unicode sequences
    data
    |> String.replace(~r/\\x\{[0-9a-fA-F]+\}/, "")
    |> String.replace(<<0xFFFD::utf8>>, "")
  end

  defp sanitize_for_json(data) when is_tuple(data) do
    # Convert tuples to lists for JSON
    data |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(%{__struct__: _} = struct) do
    # Convert structs to maps and sanitize recursively
    struct
    |> Map.from_struct()
    |> Map.drop([:embedding, :embedding_int8, :embedding_binary, :__meta__])
    |> sanitize_for_json()
  end

  defp sanitize_for_json(data), do: data

  defp format_content(result) when is_binary(result) do
    [%{"type" => "text", "text" => result}]
  end

  defp format_content(result) when is_map(result) do
    # If it's a complex object (like the output of `fetch` or `terminal`), pretty print it
    text =
      case result do
        # Terminal output
        %{status: _, output: out} -> out
        # Fetch output
        %{body: body} -> body
        _ -> Jason.encode!(result, pretty: true, escape: :unicode_safe)
      end

    [%{"type" => "text", "text" => text}]
  end

  defp format_content(result) do
    [%{"type" => "text", "text" => inspect(result)}]
  end
end
