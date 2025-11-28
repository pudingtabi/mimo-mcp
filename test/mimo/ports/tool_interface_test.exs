defmodule Mimo.ToolInterfaceTest do
  @moduledoc """
  Tests for Mimo.ToolInterface port.
  Tests tool execution, routing, and error handling.
  """
  use Mimo.DataCase, async: false

  alias Mimo.ToolInterface

  setup do
    # Ensure ToolRegistry is available
    :ok
  end

  describe "execute/2 - internal tools" do
    test "search_vibes returns results with valid query" do
      result = ToolInterface.execute("search_vibes", %{"query" => "test query"})

      assert {:ok, response} = result
      assert response.status == "success"
      assert Map.has_key?(response, :tool_call_id)
      assert Map.has_key?(response, :data)
    end

    test "search_vibes uses default limit and threshold" do
      result = ToolInterface.execute("search_vibes", %{"query" => "test"})

      assert {:ok, _response} = result
    end

    test "search_vibes accepts custom limit and threshold" do
      result =
        ToolInterface.execute("search_vibes", %{
          "query" => "test",
          "limit" => 5,
          "threshold" => 0.5
        })

      assert {:ok, response} = result
      assert response.status == "success"
    end

    test "store_fact requires content and category" do
      result = ToolInterface.execute("store_fact", %{"content" => "test fact"})

      assert {:error, message} = result
      assert message =~ "required"
    end

    test "store_fact succeeds with required fields" do
      result =
        ToolInterface.execute("store_fact", %{
          "content" => "Test fact for testing",
          "category" => "fact"
        })

      assert {:ok, response} = result
      assert response.status == "success"
      assert response.data.stored == true
    end

    test "store_fact accepts optional importance" do
      result =
        ToolInterface.execute("store_fact", %{
          "content" => "Important test fact",
          "category" => "observation",
          "importance" => 0.9
        })

      assert {:ok, response} = result
      assert response.status == "success"
    end

    test "mimo_reload_skills returns success" do
      result = ToolInterface.execute("mimo_reload_skills", %{})

      assert {:ok, response} = result
      assert response.status == "success"
      assert response.data.status == "success"
    end
  end

  describe "execute/2 - unknown tools" do
    test "returns error for completely unknown tool" do
      result = ToolInterface.execute("nonexistent_tool_xyz", %{})

      assert {:error, message} = result
      assert message =~ "Unknown tool" or message =~ "not found"
    end
  end

  describe "execute/2 - procedural store guard" do
    test "recall_procedure returns error when procedural store is disabled" do
      # This test assumes procedural_store feature flag is false by default
      result = ToolInterface.execute("recall_procedure", %{"name" => "test_procedure"})

      # Should either return an error about not enabled, or not found
      assert {:error, message} = result
      assert is_binary(message)
    end
  end

  describe "list_tools/0" do
    test "returns list of tool definitions" do
      tools = ToolInterface.list_tools()

      assert is_list(tools)
      assert length(tools) > 0

      # Verify tool structure
      first_tool = List.first(tools)
      assert is_map(first_tool)
      assert Map.has_key?(first_tool, "name") or Map.has_key?(first_tool, :name)
    end

    test "includes internal tools" do
      tools = ToolInterface.list_tools()
      tool_names = Enum.map(tools, &(&1["name"] || &1[:name]))

      assert "ask_mimo" in tool_names
      assert "search_vibes" in tool_names
      assert "store_fact" in tool_names
    end

    test "does not include removed duplicate tools" do
      tools = ToolInterface.list_tools()
      tool_names = Enum.map(tools, &(&1["name"] || &1[:name]))

      # mimo_store_memory was removed as duplicate of store_fact
      refute "mimo_store_memory" in tool_names
    end
  end
end
