defmodule Mimo.Brain.MemoryTest do
  use ExUnit.Case
  alias Mimo.Brain.Memory

  # FIX 1: specific setup for Database tests
  setup do
    # Checkout a connection from the pool so we can write to DB in tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mimo.Repo)
    # Allow WriteSerializer to use our sandbox connection (it runs in a separate process)
    Ecto.Adapters.SQL.Sandbox.allow(Mimo.Repo, self(), Mimo.Brain.WriteSerializer)
    :ok
  end

  describe "store/1" do
    test "successfully stores a simple text memory" do
      memory_item = %{
        content: "The user prefers Elixir over Python.",
        type: "fact",
        metadata: %{source: "test"}
      }

      result = Memory.store(memory_item)
      assert match?({:ok, _}, result)
    end

    test "strictly enforces map input (raises on nil)" do
      # FIX 2: The code uses a guard `when is_map`, so it RAISES error
      # instead of returning {:error, ...}. We assert the raise.
      assert_raise FunctionClauseError, fn ->
        Memory.store(nil)
      end
    end
  end

  describe "search/2" do
    test "executes search without crashing" do
      query = "Elixir preference"
      result = Memory.search(query, limit: 5)

      case result do
        {:ok, list} when is_list(list) -> assert true
        list when is_list(list) -> assert true
        _ -> flunk("Search returned unexpected format: #{inspect(result)}")
      end
    end

    test "accepts search options (strategy selection)" do
      query = "Exact match test"
      result = Memory.search(query, strategy: :exact)
      assert is_list(result) or match?({:ok, _}, result)
    end
  end

  describe "store_batch/2" do
    @tag :batch_store
    test "stores multiple memories in batch" do
      memories = [
        %{content: "Batch memory 1 for testing", category: "fact", importance: 0.7},
        %{content: "Batch memory 2 for testing", category: "observation", importance: 0.6},
        %{content: "Batch memory 3 for testing", category: "action", importance: 0.8}
      ]

      result = Memory.store_batch(memories)

      assert {:ok, %{stored: stored, ids: ids, failed: failed}} = result
      assert stored == 3
      assert length(ids) == 3
      assert failed == 0
      assert Enum.all?(ids, &is_integer/1)
    end

    @tag :batch_store
    test "returns empty result for empty list" do
      result = Memory.store_batch([])

      assert {:ok, %{stored: 0, ids: [], failed: 0}} = result
    end

    @tag :batch_store
    test "handles default values for optional fields" do
      memories = [
        %{content: "Minimal batch memory test"}
      ]

      result = Memory.store_batch(memories)

      assert {:ok, %{stored: 1, ids: [id], failed: 0}} = result
      assert is_integer(id)
    end

    @tag :batch_store
    test "fails with missing content" do
      memories = [
        %{category: "fact", importance: 0.7}
      ]

      result = Memory.store_batch(memories)

      assert {:error, :missing_content} = result
    end

    @tag :batch_store
    test "respects custom batch_size option" do
      # Create more memories than default batch size
      memories =
        for i <- 1..5 do
          %{content: "Batch size test memory #{i}", category: "fact"}
        end

      # Use small batch_size to force multiple embedding batches
      result = Memory.store_batch(memories, batch_size: 2)

      assert {:ok, %{stored: 5, ids: ids, failed: 0}} = result
      assert length(ids) == 5
    end
  end
end
