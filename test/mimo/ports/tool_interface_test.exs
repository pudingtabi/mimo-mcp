defmodule Mimo.ToolInterfaceTest do
  @moduledoc """
  Tests for Mimo.ToolInterface port.
  Tests tool execution, routing, and error handling.
  Includes SPEC-011 tool tests.
  """
  use Mimo.DataCase, async: false

  alias Mimo.ToolInterface
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  @test_dir Path.join(System.tmp_dir!(), "mimo_tool_interface_test")

  setup do
    # Ensure ToolRegistry is available
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf(@test_dir)
    end)

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

  # ============================================================================
  # SPEC-011.1: Procedural Store Tools
  # ============================================================================

  describe "execute/2 - procedural store tools" do
    test "run_procedure requires name argument" do
      result = ToolInterface.execute("run_procedure", %{})
      assert {:error, message} = result
      assert message =~ "name"
    end

    test "run_procedure returns error when procedural store is disabled" do
      result = ToolInterface.execute("run_procedure", %{"name" => "test_proc"})

      # Should return disabled message if feature flag is off
      assert {:error, message} = result
      assert is_binary(message)
    end

    test "procedure_status requires execution_id" do
      result = ToolInterface.execute("procedure_status", %{})
      assert {:error, message} = result
      assert message =~ "execution_id"
    end

    test "list_procedures returns error or list when procedural store is disabled" do
      result = ToolInterface.execute("list_procedures", %{})

      # Should either return error about disabled or empty list
      case result do
        {:error, message} ->
          assert message =~ "not enabled"

        {:ok, response} ->
          assert response.status == "success"
          assert is_list(response.data.procedures)
      end
    end
  end

  # ============================================================================
  # SPEC-011.2: Unified Memory Tool
  # ============================================================================

  describe "execute/2 - memory tool" do
    test "memory requires operation argument" do
      result = ToolInterface.execute("memory", %{})
      assert {:error, message} = result
      assert message =~ "operation"
    end

    test "memory store operation works" do
      result = ToolInterface.execute("memory", %{
        "operation" => "store",
        "content" => "Test memory content for unified tool",
        "category" => "fact",
        "importance" => 0.7
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert response.data.stored == true
      assert response.data.embedding_generated == true
    end

    test "memory store requires content" do
      result = ToolInterface.execute("memory", %{
        "operation" => "store",
        "category" => "fact"
      })

      assert {:error, message} = result
      assert message =~ "content"
    end

    test "memory search operation works" do
      # First store something
      ToolInterface.execute("memory", %{
        "operation" => "store",
        "content" => "Searchable memory content unique123",
        "category" => "fact"
      })

      result = ToolInterface.execute("memory", %{
        "operation" => "search",
        "query" => "unique123"
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert is_list(response.data.results)
    end

    test "memory search requires query" do
      result = ToolInterface.execute("memory", %{
        "operation" => "search"
      })

      assert {:error, message} = result
      assert message =~ "query"
    end

    test "memory search with time_filter" do
      result = ToolInterface.execute("memory", %{
        "operation" => "search",
        "query" => "test",
        "time_filter" => "last week"
      })

      assert {:ok, response} = result
      assert response.status == "success"
    end

    test "memory list operation works" do
      result = ToolInterface.execute("memory", %{
        "operation" => "list",
        "limit" => 5
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert is_list(response.data.memories)
      assert is_integer(response.data.total)
    end

    test "memory list with pagination" do
      result = ToolInterface.execute("memory", %{
        "operation" => "list",
        "limit" => 10,
        "offset" => 0,
        "sort" => "importance"
      })

      assert {:ok, response} = result
      assert response.data.limit == 10
      assert response.data.offset == 0
    end

    test "memory delete operation requires id" do
      result = ToolInterface.execute("memory", %{
        "operation" => "delete"
      })

      assert {:error, message} = result
      assert message =~ "id"
    end

    test "memory delete operation works" do
      # First store something
      {:ok, store_response} = ToolInterface.execute("memory", %{
        "operation" => "store",
        "content" => "Memory to be deleted",
        "category" => "fact"
      })

      id = store_response.data.id

      # Now delete it
      result = ToolInterface.execute("memory", %{
        "operation" => "delete",
        "id" => id
      })

      assert {:ok, response} = result
      assert response.data.deleted == true

      # Verify it's gone
      assert Repo.get(Engram, id) == nil
    end

    test "memory stats operation works" do
      result = ToolInterface.execute("memory", %{
        "operation" => "stats"
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert is_integer(response.data.total_memories)
      assert is_map(response.data.by_category)
    end

    test "memory decay_check operation works" do
      result = ToolInterface.execute("memory", %{
        "operation" => "decay_check",
        "threshold" => 0.1,
        "limit" => 10
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert is_list(response.data.at_risk)
      assert response.data.threshold == 0.1
    end

    test "memory unknown operation returns error" do
      result = ToolInterface.execute("memory", %{
        "operation" => "invalid_op"
      })

      assert {:error, message} = result
      assert message =~ "Unknown memory operation"
    end
  end

  # ============================================================================
  # SPEC-011.3: Ingest Tool
  # ============================================================================

  describe "execute/2 - ingest tool" do
    test "ingest requires path argument" do
      result = ToolInterface.execute("ingest", %{})
      assert {:error, message} = result
      assert message =~ "path"
    end

    test "ingest works with valid file" do
      content = "Test content paragraph one.\n\nTest content paragraph two."
      path = Path.join(@test_dir, "ingest_test.txt")
      File.write!(path, content)

      result = ToolInterface.execute("ingest", %{
        "path" => path,
        "category" => "fact"
      })

      assert {:ok, response} = result
      assert response.status == "success"
      assert response.data.chunks_created >= 1
      assert is_list(response.data.ids)
    end

    test "ingest with strategy option" do
      content = "# Header\n\nContent here.\n\n## Section\n\nMore content."
      path = Path.join(@test_dir, "markdown_test.md")
      File.write!(path, content)

      result = ToolInterface.execute("ingest", %{
        "path" => path,
        "strategy" => "markdown"
      })

      assert {:ok, response} = result
      assert response.data.strategy_used == :markdown
    end

    test "ingest with tags and metadata" do
      content = "Tagged content."
      path = Path.join(@test_dir, "tagged_test.txt")
      File.write!(path, content)

      result = ToolInterface.execute("ingest", %{
        "path" => path,
        "tags" => ["test", "ingestion"],
        "metadata" => %{"source" => "test"}
      })

      assert {:ok, response} = result
      assert response.status == "success"

      # Verify metadata was stored
      engram = Repo.get(Engram, hd(response.data.ids))
      assert engram.metadata["tags"] == ["test", "ingestion"]
    end

    test "ingest returns error for non-existent file" do
      result = ToolInterface.execute("ingest", %{
        "path" => "/nonexistent/file.txt"
      })

      assert {:error, _message} = result
    end
  end

  # ============================================================================
  # Legacy Tools (Deprecated)
  # ============================================================================

  describe "execute/2 - deprecated tools" do
    test "store_fact still works (with deprecation)" do
      result = ToolInterface.execute("store_fact", %{
        "content" => "Legacy store fact test",
        "category" => "fact"
      })

      assert {:ok, response} = result
      assert response.data.stored == true
    end

    test "search_vibes still works (with deprecation)" do
      result = ToolInterface.execute("search_vibes", %{
        "query" => "test search"
      })

      assert {:ok, response} = result
      assert response.status == "success"
    end
  end

  # ============================================================================
  # Unknown Tools
  # ============================================================================

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

  # ============================================================================
  # Tool Listing
  # ============================================================================

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

    test "includes SPEC-011 tools" do
      tools = ToolInterface.list_tools()
      tool_names = Enum.map(tools, &(&1["name"] || &1[:name]))

      # SPEC-011.1
      assert "run_procedure" in tool_names
      assert "procedure_status" in tool_names
      assert "list_procedures" in tool_names

      # SPEC-011.2
      assert "memory" in tool_names

      # SPEC-011.3
      assert "ingest" in tool_names
    end

    test "does not include removed duplicate tools" do
      tools = ToolInterface.list_tools()
      tool_names = Enum.map(tools, &(&1["name"] || &1[:name]))

      # mimo_store_memory was removed as duplicate of store_fact
      refute "mimo_store_memory" in tool_names
    end
  end
end
