defmodule Mimo.McpCli do
  @moduledoc """
  CLI entry point for one-shot MCP requests.
  Used by the mimo-mcp-stdio wrapper for VS Code communication.
  """

  # Silence logging at module load time
  @compile {:no_warn_undefined, Logger}

  @doc """
  Process all stdin lines and output JSON responses.
  Exits when stdin is closed (EOF).
  """
  def run do
    # CRITICAL: Silence logging FIRST before any other code runs
    # Logger output on stdout breaks MCP protocol
    :logger.set_primary_config(:level, :none)
    Application.put_env(:logger, :level, :none)
    Logger.configure(level: :none)

    # Force unbuffered I/O - critical for MCP over pipes/SSH
    :io.setopts(:standard_io, [:binary, {:encoding, :unicode}])
    :io.setopts(:standard_error, [:binary, {:encoding, :unicode}])

    # Ensure catalog is loaded (with logging silenced)
    wait_for_catalog()

    # Process stdin lines
    process_stdin()
  end

  defp wait_for_catalog do
    case Mimo.Skills.Catalog.list_tools() do
      tools when length(tools) > 0 -> :ok
      _ ->
        Process.sleep(100)
        wait_for_catalog()
    end
  rescue
    _ ->
      # Catalog not started, load it directly
      Mimo.Skills.Catalog.load_catalog()
      :ok
  end

  defp process_stdin do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _reason} -> :ok
      line when is_binary(line) ->
        handle_line(String.trim(line))
        process_stdin()
    end
  end

  defp handle_line(""), do: :ok
  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, request} ->
        response = handle_request(request)
        unless response == :no_response do
          # Use :io.put_chars with explicit newline and flush for immediate output
          output = Jason.encode!(response) <> "\n"
          :io.put_chars(:standard_io, output)
          # Force flush - critical for unbuffered output over pipes/ssh
          :io.setopts(:standard_io, [{:encoding, :unicode}])
        end
      {:error, _} ->
        error_response = %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32700, "message" => "Parse error"},
          "id" => nil
        }
        output = Jason.encode!(error_response) <> "\n"
        :io.put_chars(:standard_io, output)
        :io.setopts(:standard_io, [{:encoding, :unicode}])
    end
  end

  defp handle_request(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{"listChanged" => true}
        },
        "serverInfo" => %{
          "name" => "mimo-mcp",
          "version" => "2.1.0"
        }
      },
      "id" => id
    }
  end

  defp handle_request(%{"method" => "tools/list", "id" => id}) do
    # Get tools from catalog (static) + internal tools
    catalog_tools = Mimo.Skills.Catalog.list_tools()
    internal_tools = internal_tools()
    all_tools = internal_tools ++ catalog_tools

    %{
      "jsonrpc" => "2.0",
      "result" => %{"tools" => all_tools},
      "id" => id
    }
  end

  defp handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    result = case tool_name do
      "ask_mimo" -> handle_ask_mimo(arguments)
      "mimo_store_memory" -> handle_store_memory(arguments)
      "mimo_reload_skills" -> handle_reload_skills()
      _ -> handle_skill_tool(tool_name, arguments)
    end

    case result do
      {:ok, content} ->
        %{
          "jsonrpc" => "2.0",
          "result" => %{
            "content" => [%{"type" => "text", "text" => format_result(content)}]
          },
          "id" => id
        }
      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32000, "message" => to_string(reason)},
          "id" => id
        }
    end
  end

  defp handle_request(%{"method" => "notifications/initialized"}) do
    :no_response
  end

  defp handle_request(%{"method" => method, "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32601, "message" => "Method not found: #{method}"},
      "id" => id
    }
  end

  defp handle_request(%{"method" => _method}) do
    :no_response
  end

  defp handle_request(_invalid) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32600, "message" => "Invalid Request"},
      "id" => nil
    }
  end

  defp internal_tools do
    [
      %{
        "name" => "ask_mimo",
        "description" => "Consult Mimo's memory for strategic guidance. Query the AI memory system for context, patterns, and recommendations.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "The question or topic to consult about"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "mimo_store_memory",
        "description" => "Store a new memory/fact in Mimo's brain",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "The content to remember"},
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "action", "observation", "plan"],
              "description" => "Category of the memory"
            },
            "importance" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "description" => "Importance score (0-1)"
            }
          },
          "required" => ["content", "category"]
        }
      },
      %{
        "name" => "mimo_reload_skills",
        "description" => "Hot-reload all skills from skills.json without restart",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  defp handle_ask_mimo(%{"query" => query}) do
    memories = try do
      Mimo.Brain.Memory.search_memories(query, limit: 10)
    rescue
      _ -> []
    end

    case Mimo.Brain.LLM.consult_chief_of_staff(query, memories) do
      {:ok, plan} ->
        # Try to persist but don't crash if it fails
        try do
          Mimo.Brain.Memory.persist_memory(
            "Consultation: #{query} => #{String.slice(plan, 0, 200)}...",
            "observation",
            0.7
          )
        rescue
          _ -> :ok
        end
        {:ok, %{"answer" => plan, "memories_consulted" => length(memories)}}
      {:error, reason} ->
        {:error, "Brain consultation failed: #{inspect(reason)}"}
    end
  end
  defp handle_ask_mimo(_), do: {:error, "Missing required parameter: query"}

  defp handle_store_memory(%{"content" => content, "category" => category} = params) do
    importance = Map.get(params, "importance", 0.5)
    case Mimo.Brain.Memory.persist_memory(content, category, importance) do
      {:ok, id} -> {:ok, %{"stored" => true, "id" => id}}
      {:error, reason} -> {:error, "Failed to store: #{inspect(reason)}"}
    end
  end
  defp handle_store_memory(_), do: {:error, "Missing required parameters: content, category"}

  defp handle_reload_skills do
    Mimo.Skills.Catalog.reload()
    {:ok, %{"status" => "success", "message" => "Skills reloaded"}}
  end

  defp handle_skill_tool(tool_name, arguments) do
    case Mimo.Skills.Catalog.get_skill_for_tool(tool_name) do
      {:ok, skill_name, config} ->
        # Spawn skill process and call tool
        case Mimo.Skills.Client.call_tool_sync(skill_name, config, tool_name, arguments) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      {:error, :not_found} ->
        {:error, "Tool '#{tool_name}' not found"}
    end
  end

  defp format_result(result) when is_map(result), do: Jason.encode!(result, pretty: true)
  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result)
end
