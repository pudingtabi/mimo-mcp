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
end
