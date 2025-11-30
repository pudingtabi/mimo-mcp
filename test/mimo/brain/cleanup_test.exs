defmodule Mimo.Brain.CleanupTest do
  use Mimo.DataCase, async: false

  alias Mimo.Brain.Cleanup
  alias Mimo.Brain.Memory
  alias Mimo.Repo
  alias Mimo.Brain.Engram

  import Ecto.Query

  @moduletag :cleanup

  setup do
    # Clean up any existing test data
    Repo.delete_all(from(e in Engram, where: like(e.content, "TEST_%")))
    :ok
  end

  describe "force_cleanup/0" do
    test "returns cleanup statistics" do
      stats = Cleanup.force_cleanup()

      assert is_map(stats)
      assert Map.has_key?(stats, :old_memories_removed)
      assert Map.has_key?(stats, :low_importance_removed)
      assert Map.has_key?(stats, :limit_enforcement_removed)
      assert Map.has_key?(stats, :duration_ms)
      assert Map.has_key?(stats, :timestamp)
    end

    test "removes old low-importance memories" do
      # Create an old, low-importance memory
      # Use NaiveDateTime and truncate for SQLite/Ecto compatibility
      old_date =
        NaiveDateTime.utc_now()
        # 60 days ago
        |> NaiveDateTime.add(-60 * 24 * 60 * 60, :second)
        |> NaiveDateTime.truncate(:second)

      {:ok, _} =
        Repo.insert(%Engram{
          content: "TEST_OLD_LOW_IMPORTANCE",
          category: "fact",
          importance: 0.3,
          embedding: List.duplicate(0.1, 64),
          inserted_at: old_date,
          updated_at: old_date
        })

      # Verify it exists
      assert Repo.exists?(from(e in Engram, where: e.content == "TEST_OLD_LOW_IMPORTANCE"))

      # Run cleanup
      stats = Cleanup.force_cleanup()

      # Should be removed (old + low importance)
      refute Repo.exists?(from(e in Engram, where: e.content == "TEST_OLD_LOW_IMPORTANCE"))
      assert stats.old_memories_removed > 0 or stats.low_importance_removed > 0
    end

    test "preserves high-importance memories" do
      # Create an old but high-importance memory
      # Use NaiveDateTime and truncate for SQLite/Ecto compatibility
      old_date =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-60 * 24 * 60 * 60, :second)
        |> NaiveDateTime.truncate(:second)

      {:ok, _} =
        Repo.insert(%Engram{
          content: "TEST_OLD_HIGH_IMPORTANCE",
          category: "fact",
          # High importance
          importance: 0.9,
          embedding: List.duplicate(0.1, 64),
          inserted_at: old_date,
          updated_at: old_date
        })

      # Run cleanup
      Cleanup.force_cleanup()

      # Should NOT be removed (high importance)
      assert Repo.exists?(from(e in Engram, where: e.content == "TEST_OLD_HIGH_IMPORTANCE"))
    end

    test "preserves recent memories" do
      # Create a recent low-importance memory
      {:ok, _} = Memory.persist_memory("TEST_RECENT_LOW_IMPORTANCE", "fact", 0.3)

      # Run cleanup
      Cleanup.force_cleanup()

      # Should NOT be removed (recent)
      assert Repo.exists?(from(e in Engram, where: e.content == "TEST_RECENT_LOW_IMPORTANCE"))
    end
  end

  describe "cleanup_stats/0" do
    test "returns current statistics" do
      stats = Cleanup.cleanup_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_memories)
      assert Map.has_key?(stats, :by_category)
      assert Map.has_key?(stats, :by_importance)
      assert Map.has_key?(stats, :limit)
      assert Map.has_key?(stats, :usage_percent)
    end

    test "counts memories correctly" do
      # Get initial count
      initial_stats = Cleanup.cleanup_stats()
      initial_count = initial_stats.total_memories

      # Add a memory
      {:ok, _} = Memory.persist_memory("TEST_COUNT_CHECK", "observation", 0.5)

      # Check count increased
      new_stats = Cleanup.cleanup_stats()
      assert new_stats.total_memories == initial_count + 1
    end

    test "tracks importance distribution" do
      stats = Cleanup.cleanup_stats()

      assert Map.has_key?(stats.by_importance, :high)
      assert Map.has_key?(stats.by_importance, :medium)
      assert Map.has_key?(stats.by_importance, :low)
    end
  end

  describe "cleaning?/0" do
    test "returns false when not cleaning" do
      # Start the cleanup process if not already started
      case Process.whereis(Mimo.Brain.Cleanup) do
        nil ->
          {:ok, _} = Cleanup.start_link([])

        _ ->
          :ok
      end

      refute Cleanup.cleaning?()
    end
  end

  describe "configure/1" do
    test "updates configuration at runtime" do
      # Start the cleanup process if not already started
      case Process.whereis(Mimo.Brain.Cleanup) do
        nil ->
          {:ok, _} = Cleanup.start_link([])

        _ ->
          :ok
      end

      # Configure with new values
      assert :ok = Cleanup.configure(default_ttl_days: 15)

      # Reset to defaults (configuration is in-memory only)
      Cleanup.configure(default_ttl_days: 30)
    end
  end
end
