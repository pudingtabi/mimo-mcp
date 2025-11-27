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
        :ok

      {:error, reason} ->
        send_error(nil, @internal_error, "IO Error: #{inspect(reason)}")
        :ok

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
        "name" => "mimo-native",
        "version" => "2.3.0"
      }
    })
  end

  defp handle_request(%{"method" => "notifications/initialized"}) do
    # No response required for notifications
    :ok
  end

  defp handle_request(%{"method" => "tools/list", "id" => id}) do
    tools = Mimo.Tools.list_tools()
    # Transform internal tool definition to MCP format if needed
    # (Mimo.Tools structure is already MCP compliant)
    send_response(id, %{"tools" => tools})
  end

  defp handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]
    args = params["arguments"] || %{}

    case Mimo.Tools.dispatch(tool_name, args) do
      {:ok, result} ->
        content = format_content(result)
        send_response(id, %{"content" => content})

      {:error, reason} ->
        send_error(id, @internal_error, to_string(reason))
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
