defmodule Mimo.McpServer.Stdio do
  @moduledoc """
  Native Elixir implementation of the MCP Model Context Protocol over Stdio.
  Replaces the legacy Python bridge and Mimo.McpCli.
  """
  require Logger

  # JSON-RPC Error Codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @internal_error -32603

  # Timeout for tool execution (30 seconds)
  @tool_timeout 30_000

  @doc """
  Starts the Stdio server loop.
  This function blocks until EOF is received on stdin.
  """
  def start do
    # 1. Silence all logger output to stdout to prevent protocol corruption
    :logger.set_primary_config(:level, :none)
    Application.put_env(:logger, :level, :none)

    # 2. Configure IO for raw binary mode with immediate flushing
    :io.setopts(:standard_io, [:binary, {:encoding, :utf8}, {:buffer, 1024}])

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
    send_response(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{
        "tools" => %{"listChanged" => true}
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
    tools = Mimo.ToolRegistry.list_all_tools()
    send_response(id, %{"tools" => tools})
  end

  defp handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]
    args = params["arguments"] || %{}

    # Check ToolRegistry first for both internal and external tools
    case Mimo.ToolRegistry.get_tool_owner(tool_name) do
      {:ok, {:skill, skill_name, _pid, _tool_def}} ->
        # External skill - already running (with timeout)
        execute_with_timeout(
          fn ->
            Mimo.Skills.Client.call_tool(skill_name, tool_name, args)
          end,
          id
        )

      {:ok, {:skill_lazy, skill_name, config, _}} ->
        # External skill - lazy spawn (with timeout)
        execute_with_timeout(
          fn ->
            Mimo.Skills.Client.call_tool_sync(skill_name, config, tool_name, args)
          end,
          id
        )

      {:ok, {:internal, _}} ->
        # Internal tool - use ToolInterface for consistency (with timeout)
        execute_with_timeout(
          fn ->
            Mimo.ToolInterface.execute(tool_name, args)
          end,
          id
        )

      {:ok, {:mimo_core, _}} ->
        # Mimo.Tools core capabilities - use ToolInterface for consistency (with timeout)
        execute_with_timeout(
          fn ->
            Mimo.ToolInterface.execute(tool_name, args)
          end,
          id
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

  # Execute a tool function with timeout protection
  defp execute_with_timeout(fun, id) do
    task = Task.async(fun)

    case Task.yield(task, @tool_timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        content = format_content(result)
        send_response(id, %{"content" => content})

      {:ok, {:error, reason}} ->
        send_error(id, @internal_error, to_string(reason))

      nil ->
        send_error(id, @internal_error, "Tool execution timed out after #{@tool_timeout}ms")
    end
  rescue
    e ->
      send_error(id, @internal_error, "Tool execution error: #{Exception.message(e)}")
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
    json = Jason.encode!(map)
    IO.write(:stdio, json <> "\n")
    # Force flush to ensure immediate delivery
    :io.put_chars(:standard_io, [])
  end

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
        _ -> Jason.encode!(result, pretty: true)
      end

    [%{"type" => "text", "text" => text}]
  end

  defp format_content(result) do
    [%{"type" => "text", "text" => inspect(result)}]
  end
end
