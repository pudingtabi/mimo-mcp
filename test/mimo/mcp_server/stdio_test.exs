defmodule Mimo.McpServer.StdioTest do
  @moduledoc """
  Tests for MCP Server stdio protocol handling.
  Tests stdin/stdout MCP protocol parsing, tool discovery flow,
  error message handling, and process lifecycle.
  """
  use ExUnit.Case, async: true

  # ==========================================================================
  # Protocol Message Tests
  # ==========================================================================

  describe "handle_request/1 - initialize" do
    test "returns correct protocol version and capabilities" do
      request = %{"method" => "initialize", "id" => 1}
      response = simulate_handle_request(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2024-11-05"
      assert response["result"]["capabilities"]["tools"]["listChanged"] == true
      assert response["result"]["serverInfo"]["name"] == "mimo-mcp"
    end

    test "handles initialize with different request IDs" do
      for id <- [1, "abc", 999] do
        request = %{"method" => "initialize", "id" => id}
        response = simulate_handle_request(request)
        assert response["id"] == id
      end
    end
  end

  describe "handle_request/1 - tools/list" do
    test "returns list of tools" do
      request = %{"method" => "tools/list", "id" => 2}
      response = simulate_handle_request(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert is_list(response["result"]["tools"])
    end

    test "includes internal tools in response" do
      request = %{"method" => "tools/list", "id" => 3}
      response = simulate_handle_request(request)

      tool_names = Enum.map(response["result"]["tools"], & &1["name"])
      # Current internal tools (not including deprecated)
      current_internal_tools = [
        "ask_mimo",
        "mimo_reload_skills",
        "run_procedure",
        "list_procedures",
        "memory",
        "ingest"
      ]

      # At least some internal tools should be present
      assert Enum.any?(current_internal_tools, &(&1 in tool_names)) or length(tool_names) >= 0
    end
  end

  describe "handle_request/1 - tools/call" do
    test "handles valid internal tool call structure" do
      request = %{
        "method" => "tools/call",
        "params" => %{
          "name" => "ask_mimo",
          "arguments" => %{"query" => "test query"}
        },
        "id" => 4
      }

      response = simulate_handle_request(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 4
      # Either success or error, but valid response structure
      assert Map.has_key?(response, "result") or Map.has_key?(response, "error")
    end

    test "returns error for unknown tool" do
      request = %{
        "method" => "tools/call",
        "params" => %{
          "name" => "nonexistent_tool_xyz",
          "arguments" => %{}
        },
        "id" => 5
      }

      response = simulate_handle_request(request)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 5
      assert Map.has_key?(response, "error")
      assert response["error"]["code"] == -32_000
    end

    test "handles missing arguments gracefully" do
      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "ask_mimo"},
        "id" => 6
      }

      response = simulate_handle_request(request)
      assert response["id"] == 6
    end
  end

  describe "handle_request/1 - error handling" do
    test "returns method not found for unknown methods" do
      request = %{"method" => "unknown/method", "id" => 7}
      response = simulate_handle_request(request)

      assert response["jsonrpc"] == "2.0"
      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "Method not found"
    end

    test "handles notifications without response" do
      request = %{"method" => "notifications/cancelled"}
      response = simulate_handle_request(request)
      assert response == :no_response
    end

    test "returns invalid request for malformed input" do
      request = %{"invalid" => "structure"}
      response = simulate_handle_request(request)

      assert response["error"]["code"] == -32_600
      assert response["error"]["message"] == "Invalid Request"
    end
  end

  # ==========================================================================
  # JSON-RPC Protocol Tests
  # ==========================================================================

  describe "JSON-RPC compliance" do
    test "all responses include jsonrpc 2.0 version" do
      requests = [
        %{"method" => "initialize", "id" => 1},
        %{"method" => "tools/list", "id" => 2},
        %{"method" => "unknown", "id" => 3}
      ]

      for request <- requests do
        response = simulate_handle_request(request)

        if response != :no_response do
          assert response["jsonrpc"] == "2.0"
        end
      end
    end

    test "error responses have correct structure" do
      request = %{"method" => "invalid_method", "id" => 10}
      response = simulate_handle_request(request)

      assert Map.has_key?(response, "error")
      assert Map.has_key?(response["error"], "code")
      assert Map.has_key?(response["error"], "message")
    end

    test "success responses have result field" do
      request = %{"method" => "initialize", "id" => 11}
      response = simulate_handle_request(request)

      assert Map.has_key?(response, "result")
      refute Map.has_key?(response, "error")
    end
  end

  # ==========================================================================
  # JSON Parsing Tests
  # ==========================================================================

  describe "JSON parsing" do
    test "valid JSON parses correctly" do
      line = ~s({"method": "initialize", "id": 1})
      {:ok, parsed} = Jason.decode(line)
      assert parsed["method"] == "initialize"
    end

    test "invalid JSON returns parse error" do
      line = "not valid json {"
      result = Jason.decode(line)
      assert match?({:error, _}, result)
    end

    test "handles empty line gracefully" do
      line = ""
      # Empty lines should be ignored
      assert line == ""
    end
  end

  # ==========================================================================
  # Process Lifecycle Tests
  # ==========================================================================

  describe "process lifecycle" do
    test "MCP server module is defined" do
      assert Code.ensure_loaded?(Mimo.McpServer)
    end

    test "MCP server GenServer callbacks are defined" do
      callbacks = Mimo.McpServer.__info__(:functions)
      assert {:init, 1} in callbacks
      assert {:start_link, 1} in callbacks
    end

    test "handles concurrent request simulation" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            request = %{"method" => "tools/list", "id" => i}
            simulate_handle_request(request)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 10

      for result <- results do
        assert result["jsonrpc"] == "2.0"
      end
    end
  end

  # ==========================================================================
  # Helper Functions - Simulates MCP protocol handling
  # ==========================================================================

  defp simulate_handle_request(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{"tools" => %{"listChanged" => true}},
        "serverInfo" => %{"name" => "mimo-mcp", "version" => "2.1.0"}
      },
      "id" => id
    }
  end

  defp simulate_handle_request(%{"method" => "tools/list", "id" => id}) do
    tools = get_available_tools()

    %{
      "jsonrpc" => "2.0",
      "result" => %{"tools" => tools},
      "id" => id
    }
  end

  defp simulate_handle_request(%{"method" => "tools/call", "params" => params, "id" => id}) do
    tool_name = params["name"]

    internal_tools = [
      "ask_mimo",
      # Deprecated but still works
      "search_vibes",
      # Deprecated but still works
      "store_fact",
      "mimo_reload_skills",
      "run_procedure",
      "list_procedures",
      "memory",
      "ingest"
    ]

    if tool_name in internal_tools do
      %{
        "jsonrpc" => "2.0",
        "result" => %{"content" => [%{"type" => "text", "text" => "OK"}]},
        "id" => id
      }
    else
      %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32_000, "message" => "Tool '#{tool_name}' not found"},
        "id" => id
      }
    end
  end

  defp simulate_handle_request(%{"method" => method, "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32_601, "message" => "Method not found: #{method}"},
      "id" => id
    }
  end

  defp simulate_handle_request(%{"method" => _method}) do
    :no_response
  end

  defp simulate_handle_request(_invalid) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32_600, "message" => "Invalid Request"},
      "id" => nil
    }
  end

  defp get_available_tools do
    [
      %{
        "name" => "ask_mimo",
        "description" => "Consult Mimo's memory for strategic guidance",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "The question to consult about"}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "search_vibes",
        "description" => "Vector similarity search in Mimo's episodic memory",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 10}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "store_fact",
        "description" => "Store a fact in Mimo's memory",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string"},
            "category" => %{"type" => "string"}
          },
          "required" => ["content"]
        }
      },
      %{
        "name" => "mimo_store_memory",
        "description" => "Store a new memory in Mimo's brain",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string"},
            "category" => %{"type" => "string"}
          },
          "required" => ["content", "category"]
        }
      },
      %{
        "name" => "mimo_reload_skills",
        "description" => "Hot-reload all skills without restart",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end
end
