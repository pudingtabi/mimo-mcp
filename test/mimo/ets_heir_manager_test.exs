defmodule Mimo.EtsHeirManagerTest do
  @moduledoc """
  Tests for ETS Heir Manager crash recovery.
  """

  use ExUnit.Case, async: false
  alias Mimo.EtsHeirManager

  @test_table :test_heir_table

  setup do
    # Ensure EtsHeirManager is running
    case Process.whereis(EtsHeirManager) do
      nil ->
        {:ok, _pid} = EtsHeirManager.start_link([])

      _pid ->
        :ok
    end

    # Clean up test table if exists
    case :ets.whereis(@test_table) do
      :undefined -> :ok
      _tid -> :ets.delete(@test_table)
    end

    :ok
  end

  describe "create_table/3" do
    test "creates ETS table with heir" do
      table =
        EtsHeirManager.create_table(
          @test_table,
          [:named_table, :set, :public],
          self()
        )

      assert :ets.whereis(@test_table) != :undefined
      assert table == @test_table

      # Table should be usable
      :ets.insert(@test_table, {:key, "value"})
      assert :ets.lookup(@test_table, :key) == [{:key, "value"}]
    end

    test "registers table in heir manager stats" do
      EtsHeirManager.create_table(
        @test_table,
        [:named_table, :set, :public],
        self()
      )

      # Give time for async cast to complete
      Process.sleep(50)

      stats = EtsHeirManager.stats()
      assert stats.total_tables >= 1
      assert Enum.any?(stats.tables, fn t -> t.name == @test_table end)
    end
  end

  describe "crash recovery" do
    test "table is held when owner dies, not destroyed" do
      # Spawn a process that creates the table then dies
      parent = self()

      owner =
        spawn(fn ->
          EtsHeirManager.create_table(
            @test_table,
            [:named_table, :set, :public],
            self()
          )

          :ets.insert(@test_table, {:data, "important"})
          send(parent, :table_created)

          # Wait for signal to die
          receive do
            :die -> :ok
          end
        end)

      # Wait for table creation
      assert_receive :table_created, 1000

      # Verify data is there
      assert :ets.lookup(@test_table, :data) == [{:data, "important"}]

      # Kill the owner
      ref = Process.monitor(owner)
      send(owner, :die)
      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1000

      # Give time for heir to receive the table
      Process.sleep(100)

      # Table should still exist!
      assert :ets.whereis(@test_table) != :undefined

      # Data should still be there!
      assert :ets.lookup(@test_table, :data) == [{:data, "important"}]

      # Table should be marked as orphaned
      assert EtsHeirManager.table_orphaned?(@test_table)
    end

    test "new owner can reclaim table with data intact" do
      parent = self()

      # First owner creates table and dies
      owner1 =
        spawn(fn ->
          EtsHeirManager.create_table(
            @test_table,
            [:named_table, :set, :public],
            self()
          )

          :ets.insert(@test_table, {:session_id, "abc123"})
          :ets.insert(@test_table, {:user_data, %{name: "test"}})
          send(parent, :created)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :created, 1000
      send(owner1, :die)
      Process.sleep(100)

      # Second owner reclaims the table
      new_owner =
        spawn(fn ->
          case EtsHeirManager.reclaim_table(@test_table, self()) do
            {:ok, table} ->
              send(parent, {:reclaimed, table})
              # Keep alive for a bit
              Process.sleep(500)

            :not_found ->
              send(parent, :not_found)
          end
        end)

      assert_receive {:reclaimed, _table}, 1000

      # Data should still be there
      assert :ets.lookup(@test_table, :session_id) == [{:session_id, "abc123"}]
      assert :ets.lookup(@test_table, :user_data) == [{:user_data, %{name: "test"}}]

      # Table should no longer be orphaned
      refute EtsHeirManager.table_orphaned?(@test_table)

      # Clean up
      Process.exit(new_owner, :normal)
    end

    test "reclaim_table returns :not_found for non-existent table" do
      result = EtsHeirManager.reclaim_table(:nonexistent_table_xyz, self())
      assert result == :not_found
    end
  end

  describe "stats/0" do
    test "returns table statistics" do
      EtsHeirManager.create_table(
        @test_table,
        [:named_table, :set, :public],
        self()
      )

      Process.sleep(50)

      stats = EtsHeirManager.stats()

      assert is_integer(stats.total_tables)
      assert is_integer(stats.active_tables)
      assert is_integer(stats.orphaned_tables)
      assert is_list(stats.tables)
    end
  end
end
