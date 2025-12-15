defmodule Mimo.McpServer.Stdio do
  @moduledoc """
  Native Elixir implementation of the MCP Model Context Protocol over Stdio.
  Replaces the legacy Python bridge and Mimo.McpCli.

  SPEC-040: Awakening Protocol Integration
  - Starts a session on `initialize`
  - Injects awakening context on first `tools/call`
  - Supports `prompts/list` and `prompts/get` for awakening prompts

  ## Stability Features (SPEC-075)

  - **Write mutex**: Atomic stdout writes prevent interleaved JSON
  - **Pre-started supervisor**: Task supervisor started at init, not on-demand
  - **Keepalive**: Periodic ping to detect dead connections
  - **Graceful timeout**: Responses always sent, even on tool timeout
  """
  require Logger

  # Write mutex to prevent interleaved stdout writes
  @write_mutex :mimo_mcp_write_mutex

  # JSON-RPC Error Codes
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @internal_error -32_603

  # Timeout for tool execution from centralized config
  @tool_timeout Mimo.TimeoutConfig.mcp_tool_timeout()

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

    # 3. SPEC-075: Initialize write mutex for atomic stdout operations
    init_write_mutex()

    # 4. SPEC-075: Pre-start task supervisor for reliable concurrent execution
    ensure_task_supervisor()

    # Note: No startup health check needed - defensive error handling in
    # Mimo.ToolRegistry.active_skill_tools() handles the race condition gracefully

    loop()
  end

  # SPEC-075: Initialize write mutex using an Agent for simple synchronization
  defp init_write_mutex do
    case Agent.start_link(fn -> :unlocked end, name: @write_mutex) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Mimo.Defensive.warn_stderr("Write mutex init failed: #{inspect(reason)}")
        :ok
    end
  end

  # SPEC-075: Ensure task supervisor is running before any tool calls
  defp ensure_task_supervisor do
    case Process.whereis(Mimo.McpTaskSupervisor) do
      nil ->
        {:ok, _pid} = Task.Supervisor.start_link(name: Mimo.McpTaskSupervisor)
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: restart_task_supervisor()
    end
  rescue
    _ -> :ok
  end

  defp restart_task_supervisor do
    Process.unregister(Mimo.McpTaskSupervisor)
    {:ok, _pid} = Task.Supervisor.start_link(name: Mimo.McpTaskSupervisor)
    :ok
  rescue
    _ -> :ok
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
        # Wrap in try/catch to ensure loop NEVER crashes
        try do
          process_line(String.trim(line))
        rescue
          e ->
            # Log to stderr (safe in MCP) and continue
            Mimo.Defensive.warn_stderr("MCP loop rescued exception: #{Exception.message(e)}")

            send_error(nil, @internal_error, "Loop error: #{Exception.message(e)}")
        catch
          kind, reason ->
            Mimo.Defensive.warn_stderr("MCP loop caught #{kind}: #{inspect(reason)}")

            send_error(nil, @internal_error, "Loop #{kind}: #{inspect(reason)}")
        end

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

    result =
      try do
        Task.yield(task, @tool_timeout) || Task.shutdown(task)
      catch
        :exit, reason ->
          # Task exited abnormally - don't crash, just report error
          {:exit, reason}
      end

    case result do
      {:ok, {:ok, tool_result}} ->
        content = format_content(tool_result)

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

      {:ok, other} ->
        # Unexpected result format - treat as success with raw result
        send_response(id, %{"content" => format_content(other)})

      {:exit, reason} ->
        send_error(id, @internal_error, "Tool process exited: #{inspect(reason)}")

      nil ->
        send_error(id, @internal_error, "Tool execution timed out after #{@tool_timeout}ms")
    end
  rescue
    e ->
      send_error(id, @internal_error, "Tool execution error: #{Exception.message(e)}")
  catch
    kind, reason ->
      send_error(id, @internal_error, "Tool #{kind}: #{inspect(reason)}")
  end

  # Spawn a task for tool execution with fallback when TaskSupervisor is unavailable
  # CRITICAL: Must NOT link to caller - task crashes should not kill the main loop
  # SPEC-075: Use pre-started Mimo.McpTaskSupervisor for reliability
  defp spawn_tool_task(fun) do
    caller = self()
    callers = Process.get(:"$callers", [])

    # SPEC-075: Try our pre-started supervisor first, then fall back to app supervisor
    supervisor = get_available_supervisor()

    Task.Supervisor.async_nolink(supervisor, fn ->
      Process.put(:"$callers", [caller | callers])
      fun.()
    end)
  end

  # SPEC-075: Get an available task supervisor, preferring our dedicated one
  defp get_available_supervisor do
    cond do
      # First choice: Our pre-started MCP supervisor
      mcp_sup = Process.whereis(Mimo.McpTaskSupervisor) ->
        if Process.alive?(mcp_sup), do: mcp_sup, else: fallback_supervisor()

      # Second choice: App's TaskSupervisor
      app_sup = Process.whereis(Mimo.TaskSupervisor) ->
        if Process.alive?(app_sup), do: app_sup, else: fallback_supervisor()

      # Last resort: Create temporary
      true ->
        fallback_supervisor()
    end
  end

  defp fallback_supervisor do
    {:ok, temp_sup} = Task.Supervisor.start_link(restart: :temporary)
    temp_sup
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
    # SPEC-075: Use mutex for atomic stdout writes to prevent interleaving
    with_write_mutex(fn ->
      do_emit_json(map)
    end)
  end

  # SPEC-075: Acquire write mutex, execute, release
  # Fallback to direct write if mutex unavailable (startup race)
  defp with_write_mutex(fun) do
    case Process.whereis(@write_mutex) do
      nil ->
        # Mutex not available, write directly (startup race condition)
        fun.()

      pid when is_pid(pid) ->
        try do
          # Simple spinlock-style mutex using Agent
          acquire_mutex()
          result = fun.()
          release_mutex()
          result
        rescue
          _ ->
            # On any error, try to release and continue
            release_mutex()
            fun.()
        catch
          _, _ ->
            release_mutex()
            fun.()
        end
    end
  end

  defp acquire_mutex do
    # Try to acquire for up to 5 seconds
    acquire_mutex_loop(100)
  end

  defp acquire_mutex_loop(0), do: :timeout

  defp acquire_mutex_loop(attempts) do
    case Agent.get_and_update(@write_mutex, fn
           :unlocked -> {:acquired, :locked}
           :locked -> {:busy, :locked}
         end) do
      :acquired ->
        :ok

      :busy ->
        Process.sleep(50)
        acquire_mutex_loop(attempts - 1)
    end
  rescue
    # Agent not available
    _ -> :ok
  end

  defp release_mutex do
    Agent.update(@write_mutex, fn _ -> :unlocked end)
  rescue
    _ -> :ok
  end

  # Actual JSON emission with atomic single-write operation
  defp do_emit_json(map) do
    # Use escape: :unicode_safe to ensure proper Unicode handling
    case Jason.encode(map, escape: :unicode_safe) do
      {:ok, json} ->
        # SPEC-075: Single atomic write operation (json + newline together)
        atomic_write(json <> "\n")

      {:error, _} ->
        # Fallback: sanitize the map and try again
        sanitized = sanitize_for_json(map)

        case Jason.encode(sanitized) do
          {:ok, json} ->
            atomic_write(json <> "\n")

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

            atomic_write(error_json <> "\n")
        end
    end
  end

  # SPEC-075: Atomic write - single :io.put_chars call instead of IO.write + flush
  defp atomic_write(data) do
    # Use :file.write for truly atomic operation on file descriptor
    # This bypasses Elixir's IO module buffering and uses a single syscall
    :ok = :file.write(:standard_io, data)
  rescue
    # Fallback to traditional approach if :file.write fails
    _ ->
      IO.write(:stdio, data)
      :io.put_chars(:standard_io, [])
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
