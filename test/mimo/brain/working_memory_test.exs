defmodule Mimo.Brain.WorkingMemoryTest do
  use ExUnit.Case, async: false

  alias Mimo.Brain.{WorkingMemory, WorkingMemoryItem}

  setup do
    # Start the WorkingMemory GenServer if not already running
    case GenServer.whereis(WorkingMemory) do
      nil -> start_supervised!(WorkingMemory)
      _pid -> :ok
    end

    # Clear working memory before each test
    WorkingMemory.clear_all()
    :ok
  end

  describe "store/2" do
    test "stores content with default options" do
      {:ok, id} = WorkingMemory.store("Test content")
      assert is_binary(id)
    end

    test "stores content with custom importance" do
      {:ok, id} = WorkingMemory.store("Important content", importance: 0.9)
      {:ok, item} = WorkingMemory.get(id)
      assert item.importance == 0.9
    end

    test "stores content with session_id" do
      {:ok, id} = WorkingMemory.store("Session content", session_id: "sess-123")
      {:ok, item} = WorkingMemory.get(id)
      assert item.session_id == "sess-123"
    end

    test "stores content with source and tool_name" do
      {:ok, id} = WorkingMemory.store("Tool output", source: "tool_call", tool_name: "search")
      {:ok, item} = WorkingMemory.get(id)
      assert item.source == "tool_call"
      assert item.tool_name == "search"
    end
  end

  describe "get/1" do
    test "returns item by id" do
      {:ok, id} = WorkingMemory.store("Test content")
      {:ok, item} = WorkingMemory.get(id)
      assert item.content == "Test content"
    end

    test "returns error for non-existent id" do
      assert {:error, :not_found} = WorkingMemory.get("non-existent")
    end

    test "updates accessed_at on get" do
      {:ok, id} = WorkingMemory.store("Test content")
      {:ok, item1} = WorkingMemory.get(id)
      Process.sleep(10)
      {:ok, item2} = WorkingMemory.get(id)
      assert DateTime.compare(item2.accessed_at, item1.accessed_at) == :gt
    end
  end

  describe "get_recent/1" do
    test "returns most recent items" do
      WorkingMemory.store("First")
      Process.sleep(10)
      WorkingMemory.store("Second")
      Process.sleep(10)
      WorkingMemory.store("Third")

      recent = WorkingMemory.get_recent(2)
      assert length(recent) == 2
      assert hd(recent).content == "Third"
    end
  end

  describe "search/2" do
    test "finds items by content" do
      WorkingMemory.store("Apple pie recipe")
      WorkingMemory.store("Banana bread recipe")
      WorkingMemory.store("Cherry tart")

      results = WorkingMemory.search("recipe")
      assert length(results) == 2
    end

    test "search is case insensitive" do
      WorkingMemory.store("UPPERCASE content")

      results = WorkingMemory.search("uppercase")
      assert length(results) == 1
    end
  end

  describe "consolidation" do
    test "marks item for consolidation" do
      {:ok, id} = WorkingMemory.store("Test content")
      :ok = WorkingMemory.mark_for_consolidation(id)
      {:ok, item} = WorkingMemory.get(id)
      assert item.consolidation_candidate == true
    end

    test "get_consolidation_candidates returns marked items" do
      {:ok, id1} = WorkingMemory.store("Content 1")
      {:ok, _id2} = WorkingMemory.store("Content 2")
      WorkingMemory.mark_for_consolidation(id1)

      candidates = WorkingMemory.get_consolidation_candidates()
      assert length(candidates) == 1
      assert hd(candidates).content == "Content 1"
    end
  end

  describe "delete/1" do
    test "removes item from working memory" do
      {:ok, id} = WorkingMemory.store("Test content")
      :ok = WorkingMemory.delete(id)
      assert {:error, :not_found} = WorkingMemory.get(id)
    end
  end

  describe "clear_session/1" do
    test "clears all items for a session" do
      WorkingMemory.store("Session A content", session_id: "A")
      WorkingMemory.store("Session B content", session_id: "B")
      WorkingMemory.store("Another A content", session_id: "A")

      :ok = WorkingMemory.clear_session("A")

      # Session A items should be gone
      results = WorkingMemory.search("Session A")
      assert length(results) == 0

      # Session B items should remain
      results = WorkingMemory.search("Session B")
      assert length(results) == 1
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      WorkingMemory.store("Content 1")
      WorkingMemory.store("Content 2")

      stats = WorkingMemory.stats()
      assert stats.count == 2
      assert stats.total_stored >= 2
    end
  end
end
