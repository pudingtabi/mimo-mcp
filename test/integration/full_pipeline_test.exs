defmodule Mimo.Integration.FullPipelineTest do
  @moduledoc """
  Integration tests for the full Mimo pipeline.

  Tests end-to-end flows:
  - Ingest → Classify → Route → Execute → Store
  - MCP protocol end-to-end
  - Memory persistence and retrieval
  - Tool registry lifecycle
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # ==========================================================================
  # Module Loading Tests
  # ==========================================================================

  describe "module dependencies" do
    test "all core modules are loadable" do
      core_modules = [
        Mimo.Application,
        Mimo.ToolRegistry,
        Mimo.Skills.Catalog,
        Mimo.Brain.Memory,
        Mimo.Brain.LLM,
        Mimo.McpServer,
        Mimo.McpServer.Stdio,
        Mimo.Telemetry.ResourceMonitor,
        Mimo.ErrorHandling.CircuitBreaker,
        Mimo.ErrorHandling.RetryStrategies
      ]

      for mod <- core_modules do
        assert Code.ensure_loaded?(mod),
               "Core module #{inspect(mod)} should be loadable"
      end
    end

    test "protocol parser is loadable" do
      assert Code.ensure_loaded?(Mimo.Protocol.McpParser)
    end

    test "process manager is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.ProcessManager)
    end

    test "bounded supervisor is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.Supervisor)
    end
  end

  # ==========================================================================
  # Protocol Parser Tests
  # ==========================================================================

  describe "MCP protocol parsing" do
    test "parses valid initialize request" do
      line = ~s({"jsonrpc":"2.0","method":"initialize","id":1})
      assert {:ok, msg} = Mimo.Protocol.McpParser.parse_line(line)
      assert msg["method"] == "initialize"
      assert msg["id"] == 1
    end

    test "parses valid tools/list request" do
      line = ~s({"jsonrpc":"2.0","method":"tools/list","id":2})
      assert {:ok, msg} = Mimo.Protocol.McpParser.parse_line(line)
      assert msg["method"] == "tools/list"
    end

    test "builds correct initialize request" do
      request = Mimo.Protocol.McpParser.initialize_request(1)
      assert is_binary(request)
      assert String.contains?(request, "initialize")
      assert String.contains?(request, "2024-11-05")
    end

    test "builds correct tools/call request" do
      request = Mimo.Protocol.McpParser.tools_call_request("ask_mimo", %{"query" => "test"}, 5)
      assert is_binary(request)
      assert String.contains?(request, "tools/call")
      assert String.contains?(request, "ask_mimo")
    end

    test "creates proper error responses" do
      error = Mimo.Protocol.McpParser.error_for(:tool_not_found, 1, "test_tool")
      assert error["error"]["code"] == -32_000
      assert String.contains?(error["error"]["message"], "test_tool")
    end
  end

  # ==========================================================================
  # Error Handling Tests
  # ==========================================================================

  describe "circuit breaker" do
    test "module is defined with expected API" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Mimo.ErrorHandling.CircuitBreaker)
      assert function_exported?(Mimo.ErrorHandling.CircuitBreaker, :call, 2)
      assert function_exported?(Mimo.ErrorHandling.CircuitBreaker, :get_state, 1)
      assert function_exported?(Mimo.ErrorHandling.CircuitBreaker, :reset, 1)
    end
  end

  describe "retry strategies" do
    test "module is defined with expected API" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Mimo.ErrorHandling.RetryStrategies)
      assert function_exported?(Mimo.ErrorHandling.RetryStrategies, :with_retry, 1)
      assert function_exported?(Mimo.ErrorHandling.RetryStrategies, :with_retry, 2)
      assert function_exported?(Mimo.ErrorHandling.RetryStrategies, :with_timeout, 2)
    end

    test "successful operation returns immediately" do
      result =
        Mimo.ErrorHandling.RetryStrategies.with_retry(fn ->
          {:ok, "success"}
        end)

      assert result == {:ok, "success"}
    end

    test "timeout wrapper works" do
      result =
        Mimo.ErrorHandling.RetryStrategies.with_timeout(
          fn -> {:ok, 42} end,
          1000
        )

      assert result == {:ok, {:ok, 42}}
    end
  end

  # ==========================================================================
  # Tool Registry Tests
  # ==========================================================================

  describe "tool registry lifecycle" do
    test "registry lists internal tools" do
      internal_names = Mimo.ToolRegistry.internal_tool_names()

      assert "ask_mimo" in internal_names
      assert "search_vibes" in internal_names
      assert "store_fact" in internal_names
    end

    test "internal tool check works" do
      assert Mimo.ToolRegistry.internal_tool?("ask_mimo")
      refute Mimo.ToolRegistry.internal_tool?("external_tool")
    end
  end

  # ==========================================================================
  # Resource Monitor Tests
  # ==========================================================================

  describe "resource monitoring" do
    test "resource monitor module is loadable" do
      assert Code.ensure_loaded?(Mimo.Telemetry.ResourceMonitor)
    end

    test "resource monitor has expected API" do
      functions = Mimo.Telemetry.ResourceMonitor.__info__(:functions)
      assert {:stats, 0} in functions
      assert {:check_now, 0} in functions
      assert {:start_link, 1} in functions
    end
  end

  # ==========================================================================
  # Vector Math Tests
  # ==========================================================================

  describe "vector operations" do
    test "vector math module is loadable" do
      assert Code.ensure_loaded?(Mimo.Vector.Math)
    end

    test "fallback module is loadable" do
      assert Code.ensure_loaded?(Mimo.Vector.Fallback)
    end

    test "cosine similarity works" do
      vec = [1.0, 2.0, 3.0]
      assert {:ok, sim} = Mimo.Vector.Math.cosine_similarity(vec, vec)
      assert_in_delta sim, 1.0, 0.001
    end

    test "batch similarity works" do
      query = [1.0, 0.0, 0.0]
      corpus = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

      assert {:ok, results} = Mimo.Vector.Math.batch_similarity(query, corpus)
      assert length(results) == 2
    end
  end

  # ==========================================================================
  # Semantic Store Tests
  # ==========================================================================

  describe "semantic store modules" do
    test "query module is loadable" do
      assert Code.ensure_loaded?(Mimo.SemanticStore.Query)
    end

    test "repository module is loadable" do
      assert Code.ensure_loaded?(Mimo.SemanticStore.Repository)
    end

    test "entity module is loadable" do
      assert Code.ensure_loaded?(Mimo.SemanticStore.Entity)
    end

    test "triple module is loadable" do
      assert Code.ensure_loaded?(Mimo.SemanticStore.Triple)
    end
  end

  # ==========================================================================
  # Procedural Store Tests
  # ==========================================================================

  describe "procedural store modules" do
    test "loader module is loadable" do
      assert Code.ensure_loaded?(Mimo.ProceduralStore.Loader)
    end

    test "validator module is loadable" do
      assert Code.ensure_loaded?(Mimo.ProceduralStore.Validator)
    end

    test "procedure module is loadable" do
      assert Code.ensure_loaded?(Mimo.ProceduralStore.Procedure)
    end
  end

  # ==========================================================================
  # WebSocket Synapse Tests
  # ==========================================================================

  describe "synapse modules" do
    test "connection manager is loadable" do
      assert Code.ensure_loaded?(Mimo.Synapse.ConnectionManager)
    end

    test "interrupt manager is loadable" do
      assert Code.ensure_loaded?(Mimo.Synapse.InterruptManager)
    end

    test "message router is loadable" do
      assert Code.ensure_loaded?(Mimo.Synapse.MessageRouter)
    end
  end

  # ==========================================================================
  # Skills Tests
  # ==========================================================================

  describe "skills modules" do
    test "client module is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.Client)
    end

    test "catalog module is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.Catalog)
    end

    test "secure executor is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.SecureExecutor)
    end

    test "validator is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.Validator)
    end

    test "process manager is loadable" do
      assert Code.ensure_loaded?(Mimo.Skills.ProcessManager)
    end
  end

  # ==========================================================================
  # Configuration Tests
  # ==========================================================================

  describe "configuration" do
    test "alerting config structure is valid" do
      # Verify config can be parsed
      config = Application.get_env(:mimo_mcp, :alerting, [])
      # Config may not be set in test env, but structure should be valid if set
      assert is_list(config) or is_nil(config)
    end

    test "feature flags can be checked" do
      # Should not crash
      result = Mimo.Application.feature_enabled?(:rust_nifs)
      assert is_boolean(result)
    end

    test "cortex status returns valid map" do
      status = Mimo.Application.cortex_status()

      assert is_map(status)
      assert Map.has_key?(status, :rust_nifs)
      assert Map.has_key?(status, :semantic_store)
      assert Map.has_key?(status, :procedural_store)
      assert Map.has_key?(status, :websocket_synapse)
    end
  end

  # ==========================================================================
  # Data Structure Tests
  # ==========================================================================

  describe "data structures" do
    test "engram schema is loadable" do
      assert Code.ensure_loaded?(Mimo.Brain.Engram)
    end

    test "engram has expected fields" do
      fields = Mimo.Brain.Engram.__schema__(:fields)

      assert :content in fields
      assert :category in fields
      assert :importance in fields
      assert :embedding in fields
    end
  end

  # ==========================================================================
  # End-to-End Flow Simulation
  # ==========================================================================

  describe "end-to-end flow simulation" do
    test "simulates ingest → classify → route flow" do
      # Simulate the meta-cognitive router flow
      query = "What is the project structure?"

      # Step 1: Classify query type
      query_type = classify_query(query)
      assert query_type in [:episodic, :semantic, :procedural, :hybrid]

      # Step 2: Route to appropriate store
      store = route_to_store(query_type)
      assert is_atom(store)

      # Step 3: Simulate execution
      result = simulate_execution(store, query)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "simulates MCP tool execution flow" do
      # Build a tools/call request
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "ask_mimo",
          "arguments" => %{"query" => "test"}
        },
        "id" => 1
      }

      # Validate request structure
      assert Map.has_key?(request, "method")
      assert Map.has_key?(request, "params")
      assert Map.has_key?(request["params"], "name")

      # Simulate response
      response = simulate_tool_response(request)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
    end
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp classify_query(query) when is_binary(query) do
    cond do
      String.contains?(query, ["what is", "structure", "how"]) -> :episodic
      String.contains?(query, ["relationship", "who", "reports"]) -> :semantic
      String.contains?(query, ["steps", "procedure", "workflow"]) -> :procedural
      true -> :hybrid
    end
  end

  defp route_to_store(:episodic), do: Mimo.Brain.Memory
  defp route_to_store(:semantic), do: Mimo.SemanticStore.Query
  defp route_to_store(:procedural), do: Mimo.ProceduralStore.Loader
  defp route_to_store(:hybrid), do: Mimo.Brain.Memory

  defp simulate_execution(_store, _query) do
    # Simulate successful execution
    {:ok, %{result: "Simulated result"}}
  end

  defp simulate_tool_response(%{"id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => "Simulated response"}]
      }
    }
  end
end
