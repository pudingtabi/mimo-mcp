defmodule Mimo.McpServer do
  @moduledoc """
  Main MCP Server entry point. Routes tool calls to skills or internal brain.
  Implements JSON-RPC 2.0 over stdio.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 9000)
    Logger.info("MCP Server initializing on port #{port}")
    
    # Start reading from stdin
    spawn_link(fn -> read_loop() end)
    
    {:ok, %{port: port}}
  end

  defp read_loop do
    case IO.read(:stdio, :line) do
      :eof -> 
        Logger.info("MCP Server: EOF received")
        :ok
      {:error, reason} ->
        Logger.error("MCP Server read error: #{inspect(reason)}")
        :ok
      line when is_binary(line) ->
        handle_line(String.trim(line))
        read_loop()
    end
  end

  defp handle_line(""), do: :ok
  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, request} ->
        case handle_request(request) do
          :no_response -> :ok  # Notifications don't get responses
          response -> IO.puts(Jason.encode!(response))
        end
      {:error, _} ->
        error_response = %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32700, "message" => "Parse error"},
          "id" => nil
        }
        IO.puts(Jason.encode!(error_response))
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
    tools = Mimo.Registry.list_all_tools()
    %{
      "jsonrpc" => "2.0",
      "result" => %{"tools" => tools},
      "id" => id
    }
  end

  defp handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    
    Logger.info("Tool call: #{tool_name}")
    
    result = case Mimo.Registry.get_tool_owner(tool_name) do
      {:ok, {:internal, :ask_mimo}} ->
        handle_ask_mimo(arguments)

      {:ok, {:internal, :store_memory}} ->
        handle_store_memory(arguments)

      {:ok, {:internal, :reload}} ->
        handle_reload_skills()

      {:ok, {:skill, skill_name, _client_pid}} ->
        Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments)
      
      {:error, :not_found} ->
        available = Mimo.Registry.list_all_tools() |> Enum.map(& &1["name"])
        {:error, "Tool '#{tool_name}' not found. Available: #{inspect(available)}"}
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

  defp handle_request(%{"method" => method, "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32601, "message" => "Method not found: #{method}"},
      "id" => id
    }
  end

  defp handle_request(%{"method" => _method}) do
    # Notification - no response needed
    :no_response
  end

  defp handle_request(_invalid) do
    # Malformed request
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32600, "message" => "Invalid Request"},
      "id" => nil
    }
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
    case Mimo.Registry.reload_skills() do
      {:ok, :reloaded} -> 
        {:ok, %{"status" => "success", "message" => "Skills reloaded"}}
      {:error, reason} -> 
        {:error, "Reload failed: #{inspect(reason)}"}
    end
  end

  defp format_result(result) when is_map(result), do: Jason.encode!(result, pretty: true)
  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result)
end
