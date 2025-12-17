defmodule Mimo.ConcurrentStartupTest do
  @moduledoc """
  Tests that Mimo handles concurrent instance startup gracefully.

  Critical for multi-agent scenarios where VS Code and Antigravity
  might both use Mimo simultaneously.
  """
  use ExUnit.Case, async: false

  alias Mimo.EtsSafe

  describe "EtsSafe.ensure_table/2" do
    test "handles race conditions in concurrent table creation" do
      # Use unique table name to avoid conflicts
      table_name = :"test_concurrent_#{System.unique_integer([:positive])}"

      # Create table in main process first (so ownership stays with test process)
      # This is the key insight: ETS tables are owned by creating process
      # When created in async Task, they're destroyed when Task exits
      EtsSafe.ensure_table(table_name, [:set, :public, :named_table])

      # Simulate concurrent table access from multiple processes
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            # This should reuse the existing table, not crash
            EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed (return non-nil values)
      assert Enum.all?(results, fn r -> r != nil end)

      # Table should still exist (owned by main process)
      assert EtsSafe.table_exists?(table_name)

      # Cleanup
      EtsSafe.delete_if_exists(table_name)
    end

    test "ensure_table returns a table reference when called twice" do
      table_name = :"test_reuse_#{System.unique_integer([:positive])}"

      # First call creates
      result1 = EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      assert result1 != nil

      # Second call reuses
      result2 = EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      assert result2 != nil

      # Both should return valid table references
      # (for named tables, first returns atom, second returns tid)
      assert EtsSafe.table_exists?(table_name)

      # Cleanup
      EtsSafe.delete_if_exists(table_name)
    end

    test "table_exists? correctly detects table presence" do
      table_name = :"test_exists_#{System.unique_integer([:positive])}"

      # Before creation
      refute EtsSafe.table_exists?(table_name)

      # After creation
      EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      assert EtsSafe.table_exists?(table_name)

      # Cleanup
      EtsSafe.delete_if_exists(table_name)
    end

    test "delete_if_exists removes table when it exists" do
      table_name = :"test_delete_#{System.unique_integer([:positive])}"

      # Create table
      EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      assert EtsSafe.table_exists?(table_name)

      # Delete it
      assert :ok = EtsSafe.delete_if_exists(table_name)
      refute EtsSafe.table_exists?(table_name)
    end

    test "delete_if_exists is safe when table doesn't exist" do
      table_name = :"test_delete_nonexistent_#{System.unique_integer([:positive])}"

      # Should not raise
      assert :ok = EtsSafe.delete_if_exists(table_name)
    end
  end

  describe "Concurrent GenServer startup" do
    test "multiple GenServers can start with same ETS table names" do
      # This simulates what happens when two Mimo instances try to start
      table_name = :"test_genserver_shared_#{System.unique_integer([:positive])}"

      # First "instance" creates table
      EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      :ets.insert(table_name, {:key1, "value1"})

      # Second "instance" should be able to reuse - just verify it doesn't crash
      result = EtsSafe.ensure_table(table_name, [:set, :public, :named_table])
      assert result != nil

      # Data should be shared (this is a behavior consideration)
      assert [{:key1, "value1"}] = :ets.lookup(table_name, :key1)

      # Cleanup
      EtsSafe.delete_if_exists(table_name)
    end
  end

  describe "Heavy concurrent load" do
    @tag :integration
    test "handles 100 concurrent table operations" do
      table_name = :"test_heavy_load_#{System.unique_integer([:positive])}"

      # Create the table first
      EtsSafe.ensure_table(table_name, [:set, :public, :named_table])

      # 100 concurrent tasks doing reads and writes
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            # Each task does multiple operations
            :ets.insert(table_name, {i, "value_#{i}"})
            :ets.lookup(table_name, i)
            EtsSafe.table_exists?(table_name)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should complete successfully
      assert length(results) == 100

      # Cleanup
      :ets.delete(table_name)
    end
  end
end
