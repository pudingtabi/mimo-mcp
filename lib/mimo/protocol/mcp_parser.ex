defmodule Mimo.Protocol.McpParser do
  @moduledoc """
  MCP Protocol Parser - Handles JSON-RPC message parsing and serialization.

  Extracted from client.ex to separate concerns:
  - Protocol parsing/serialization
  - Error code handling
  - Message validation

  ## JSON-RPC Error Codes

  Standard JSON-RPC 2.0 error codes:
  - -32700: Parse error
  - -32600: Invalid Request  
  - -32601: Method not found
  - -32602: Invalid params
  - -32603: Internal error

  MCP-specific error codes (-32000 to -32099):
  - -32000: Tool not found
  - -32001: Tool execution failed
  - -32002: Skill unavailable
  """
  require Logger

  # JSON-RPC Error Codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # MCP-specific error codes
  @tool_not_found -32000
  @tool_execution_failed -32001
  @skill_unavailable -32002

  # ==========================================================================
  # Parsing
  # ==========================================================================

  @doc """
  Parses a JSON-RPC message line.

  Returns {:ok, message} or {:error, error_response}.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:ok, :empty} | {:error, map()}
  def parse_line(""), do: {:ok, :empty}

  def parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, :empty}
    else
      trimmed
      |> Jason.decode()
      |> case do
        {:ok, message} when is_map(message) ->
          validate_message(message)

        {:ok, _not_map} ->
          {:error, error_response(nil, @invalid_request, "Request must be a JSON object")}

        {:error, %Jason.DecodeError{} = e} ->
          Logger.debug("JSON parse error: #{Exception.message(e)}")
          {:error, error_response(nil, @parse_error, "Parse error")}
      end
    end
  end

  @doc """
  Validates a JSON-RPC message structure.
  """
  @spec validate_message(map()) :: {:ok, map()} | {:error, map()}
  def validate_message(%{"jsonrpc" => version} = msg) when version != "2.0" do
    id = Map.get(msg, "id")
    {:error, error_response(id, @invalid_request, "Invalid JSON-RPC version")}
  end

  def validate_message(%{"method" => method} = msg) when is_binary(method) do
    {:ok, msg}
  end

  def validate_message(%{"id" => id}) do
    {:error, error_response(id, @invalid_request, "Missing method")}
  end

  def validate_message(_msg) do
    {:error, error_response(nil, @invalid_request, "Invalid Request")}
  end

  @doc """
  Parses a buffer containing potentially multiple JSON-RPC messages.
  Returns the first complete message and remaining buffer.
  """
  @spec parse_buffer(String.t()) ::
          {:ok, map(), String.t()} | {:incomplete, String.t()} | {:error, map()}
  def parse_buffer(buffer) do
    buffer
    |> String.split("\n", parts: 2)
    |> case do
      [""] ->
        {:incomplete, buffer}

      [_line] ->
        {:incomplete, buffer}

      [line, rest] ->
        case parse_line(line) do
          {:ok, :empty} -> parse_buffer(rest)
          {:ok, msg} -> {:ok, msg, rest}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Finds a valid JSON-RPC response in a buffer (handles multi-line output).
  Used when parsing responses from skill processes.
  """
  @spec find_json_response(String.t()) :: {:ok, map(), String.t()} | :incomplete
  def find_json_response(buffer) do
    buffer
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:incomplete, fn line, _acc ->
      case Jason.decode(line) do
        {:ok, %{"jsonrpc" => "2.0"} = response} ->
          {:halt, {:ok, response, ""}}

        _ ->
          {:cont, :incomplete}
      end
    end)
  end

  # ==========================================================================
  # Serialization
  # ==========================================================================

  @doc """
  Creates a JSON-RPC success response.
  """
  @spec success_response(any(), any()) :: map()
  def success_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  @doc """
  Creates a JSON-RPC error response.
  """
  @spec error_response(any(), integer(), String.t(), any()) :: map()
  def error_response(id, code, message, data \\ nil) do
    error = %{
      "code" => code,
      "message" => message
    }

    # Convert atom keys to string keys if data is a map
    data =
      if is_map(data) and not is_struct(data) do
        for {k, v} <- data, into: %{} do
          {to_string(k), v}
        end
      else
        data
      end

    error = if data, do: Map.put(error, "data", data), else: error

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    }
  end

  @doc """
  Encodes a response to JSON with newline.
  """
  @spec encode_response(map()) :: String.t()
  def encode_response(response) do
    Jason.encode!(response) <> "\n"
  end

  # ==========================================================================
  # Request Building
  # ==========================================================================

  @doc """
  Builds an initialize request.
  """
  @spec initialize_request(integer()) :: String.t()
  def initialize_request(id \\ 1) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mimo-mcp", "version" => "2.4.0"}
      },
      "id" => id
    }

    Jason.encode!(request) <> "\n"
  end

  @doc """
  Builds an initialized notification.
  """
  @spec initialized_notification() :: String.t()
  def initialized_notification do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    }

    Jason.encode!(notification) <> "\n"
  end

  @doc """
  Builds a tools/list request.
  """
  @spec tools_list_request(integer()) :: String.t()
  def tools_list_request(id \\ 2) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => id
    }

    Jason.encode!(request) <> "\n"
  end

  @doc """
  Builds a tools/call request.
  """
  @spec tools_call_request(String.t(), map(), integer()) :: String.t()
  def tools_call_request(tool_name, arguments, id) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      },
      "id" => id
    }

    Jason.encode!(request) <> "\n"
  end

  # ==========================================================================
  # Error Code Helpers
  # ==========================================================================

  @doc "Returns the parse error code."
  def parse_error_code, do: @parse_error

  @doc "Returns the invalid request error code."
  def invalid_request_code, do: @invalid_request

  @doc "Returns the method not found error code."
  def method_not_found_code, do: @method_not_found

  @doc "Returns the invalid params error code."
  def invalid_params_code, do: @invalid_params

  @doc "Returns the internal error code."
  def internal_error_code, do: @internal_error

  @doc "Returns the tool not found error code."
  def tool_not_found_code, do: @tool_not_found

  @doc "Returns the tool execution failed error code."
  def tool_execution_failed_code, do: @tool_execution_failed

  @doc "Returns the skill unavailable error code."
  def skill_unavailable_code, do: @skill_unavailable

  @doc """
  Creates a standard error response for a given error type.
  """
  @spec error_for(atom(), any(), any()) :: map()
  def error_for(:parse_error, id, _data) do
    error_response(id, @parse_error, "Parse error")
  end

  def error_for(:invalid_request, id, _data) do
    error_response(id, @invalid_request, "Invalid Request")
  end

  def error_for(:method_not_found, id, method) do
    error_response(id, @method_not_found, "Method not found: #{method}")
  end

  def error_for(:tool_not_found, id, tool_name) do
    error_response(id, @tool_not_found, "Tool '#{tool_name}' not found")
  end

  def error_for(:tool_execution_failed, id, reason) do
    error_response(id, @tool_execution_failed, "Tool execution failed", reason)
  end

  def error_for(:skill_unavailable, id, skill_name) do
    error_response(id, @skill_unavailable, "Skill '#{skill_name}' is unavailable")
  end

  def error_for(:internal_error, id, message) do
    error_response(id, @internal_error, to_string(message))
  end
end
