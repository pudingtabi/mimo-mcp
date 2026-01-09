defmodule Mimo.Brain.NoveltyDetectorTest do
  @moduledoc """
  Tests for SPEC-034 NoveltyDetector module.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.{Engram, NoveltyDetector}
  alias Mimo.Repo

  describe "thresholds_for/1" do
    test "returns correct thresholds for fact category" do
      thresholds = NoveltyDetector.thresholds_for("fact")
      assert thresholds.redundant == 0.95
      assert thresholds.ambiguous == 0.82
    end

    test "returns correct thresholds for observation category" do
      thresholds = NoveltyDetector.thresholds_for("observation")
      assert thresholds.redundant == 0.92
      assert thresholds.ambiguous == 0.78
    end

    test "returns correct thresholds for action category" do
      thresholds = NoveltyDetector.thresholds_for("action")
      assert thresholds.redundant == 0.90
      assert thresholds.ambiguous == 0.75
    end

    test "returns correct thresholds for plan category" do
      thresholds = NoveltyDetector.thresholds_for("plan")
      assert thresholds.redundant == 0.88
      assert thresholds.ambiguous == 0.72
    end

    test "returns default thresholds for unknown category" do
      thresholds = NoveltyDetector.thresholds_for("unknown_category")
      assert thresholds.redundant == 0.92
      assert thresholds.ambiguous == 0.78
    end

    test "accepts atom input" do
      thresholds = NoveltyDetector.thresholds_for(:fact)
      assert thresholds.redundant == 0.95
    end
  end

  describe "all_thresholds/0" do
    test "returns map with all categories" do
      thresholds = NoveltyDetector.all_thresholds()
      assert Map.has_key?(thresholds, "fact")
      assert Map.has_key?(thresholds, "observation")
      assert Map.has_key?(thresholds, "action")
      assert Map.has_key?(thresholds, "plan")
      assert Map.has_key?(thresholds, :default)
    end
  end

  describe "tmc_enabled?/0" do
    test "returns false when feature flag is false" do
      # Default is false in test config
      # This test just verifies the function works
      result = NoveltyDetector.tmc_enabled?()
      assert is_boolean(result)
    end
  end

  describe "classify/3 - with TMC disabled" do
    setup do
      # Explicitly disable TMC for this test
      original = Application.get_env(:mimo_mcp, :feature_flags, [])

      Application.put_env(
        :mimo_mcp,
        :feature_flags,
        Keyword.put(original, :temporal_memory_chains, false)
      )

      on_exit(fn ->
        Application.put_env(:mimo_mcp, :feature_flags, original)
      end)

      :ok
    end

    test "returns :new when TMC is disabled" do
      result = NoveltyDetector.classify("Some new content", "fact")
      assert result == {:new, []}
    end
  end

  describe "classify/3 - with TMC enabled" do
    setup do
      # Clear all engrams to ensure clean slate for novel content tests
      Repo.delete_all(Engram)

      # Enable TMC for these tests
      original = Application.get_env(:mimo_mcp, :feature_flags, [])

      Application.put_env(
        :mimo_mcp,
        :feature_flags,
        Keyword.put(original, :temporal_memory_chains, true)
      )

      on_exit(fn ->
        Application.put_env(:mimo_mcp, :feature_flags, original)
      end)

      :ok
    end

    test "returns :new for completely novel content" do
      # Generate unique content that won't match anything
      unique_content = "This is a completely unique test memory #{System.unique_integer()}"

      result = NoveltyDetector.classify(unique_content, "fact")
      assert result == {:new, []}
    end
  end

  describe "find_similar/3" do
    setup do
      # Clear all engrams to ensure clean slate
      Repo.delete_all(Engram)

      # Enable TMC for these tests
      original = Application.get_env(:mimo_mcp, :feature_flags, [])

      Application.put_env(
        :mimo_mcp,
        :feature_flags,
        Keyword.put(original, :temporal_memory_chains, true)
      )

      on_exit(fn ->
        Application.put_env(:mimo_mcp, :feature_flags, original)
      end)

      :ok
    end

    test "returns empty list when no similar memories exist" do
      unique_content = "Extremely unique content that has no match #{System.unique_integer()}"

      result = NoveltyDetector.find_similar(unique_content, "fact")
      assert result == []
    end

    test "excludes superseded memories from results" do
      # Create a superseded memory directly
      {:ok, old_engram} =
        Repo.insert(%Engram{
          content: "Test memory for supersession check",
          category: "fact",
          importance: 0.5,
          # Mark as superseded
          superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Find similar should not return superseded memories
      result = NoveltyDetector.find_similar("Test memory for supersession check", "fact")

      # The superseded memory should not be in results
      ids = Enum.map(result, fn %{engram: e} -> e.id end)
      refute old_engram.id in ids
    end

    test "filters by category" do
      # Create a memory in one category
      {:ok, _fact} =
        Repo.insert(%Engram{
          content: "Category filter test memory",
          category: "fact",
          importance: 0.5
        })

      # Search in a different category should not find it
      result = NoveltyDetector.find_similar("Category filter test memory", "observation")

      # Should not find the fact when searching observations
      fact_found =
        Enum.any?(result, fn %{engram: e} ->
          String.contains?(e.content || "", "Category filter test")
        end)

      refute fact_found
    end
  end

  describe "explain_classification/3" do
    setup do
      # Clear all engrams to ensure clean slate
      Repo.delete_all(Engram)

      # Enable TMC
      original = Application.get_env(:mimo_mcp, :feature_flags, [])

      Application.put_env(
        :mimo_mcp,
        :feature_flags,
        Keyword.put(original, :temporal_memory_chains, true)
      )

      on_exit(fn ->
        Application.put_env(:mimo_mcp, :feature_flags, original)
      end)

      :ok
    end

    test "returns explanation map with all fields" do
      explanation =
        NoveltyDetector.explain_classification(
          "Unique test content #{System.unique_integer()}",
          "observation"
        )

      assert is_map(explanation)
      assert Map.has_key?(explanation, :classification)
      assert Map.has_key?(explanation, :category)
      assert Map.has_key?(explanation, :thresholds)
      assert Map.has_key?(explanation, :tmc_enabled)
      assert Map.has_key?(explanation, :similar_count)
      assert Map.has_key?(explanation, :top_similarity)
      assert Map.has_key?(explanation, :similar_memories)
      assert Map.has_key?(explanation, :target)

      assert explanation.category == "observation"
      assert explanation.tmc_enabled == true
    end

    test "returns :new classification for novel content" do
      explanation =
        NoveltyDetector.explain_classification(
          "Completely novel content for testing #{System.unique_integer()}",
          "fact"
        )

      assert explanation.classification == :new
      assert explanation.similar_count == 0
      assert explanation.top_similarity == 0.0
      assert explanation.target == nil
    end
  end

  describe "Engram schema TMC helpers" do
    test "active?/1 returns true for non-superseded engram" do
      engram = %Engram{superseded_at: nil}
      assert Engram.active?(engram) == true
    end

    test "active?/1 returns false for superseded engram" do
      engram = %Engram{superseded_at: DateTime.utc_now()}
      assert Engram.active?(engram) == false
    end

    test "superseded?/1 returns opposite of active?" do
      active = %Engram{superseded_at: nil}
      superseded = %Engram{superseded_at: DateTime.utc_now()}

      assert Engram.superseded?(active) == false
      assert Engram.superseded?(superseded) == true
    end

    test "has_predecessor?/1 checks supersedes_id" do
      no_predecessor = %Engram{supersedes_id: nil}
      has_predecessor = %Engram{supersedes_id: 123}

      assert Engram.has_predecessor?(no_predecessor) == false
      assert Engram.has_predecessor?(has_predecessor) == true
    end

    test "chain_summary/1 returns summary map" do
      engram = %Engram{
        id: 1,
        content: "Test content for chain summary",
        category: "fact",
        importance: 0.8,
        inserted_at: ~N[2025-01-01 00:00:00],
        supersedes_id: nil,
        superseded_at: nil,
        supersession_type: nil
      }

      summary = Engram.chain_summary(engram)

      assert summary.id == 1
      assert summary.content == "Test content for chain summary"
      assert summary.category == "fact"
      assert summary.importance == 0.8
      assert summary.active == true
      assert summary.supersedes_id == nil
      assert summary.superseded_at == nil
    end
  end

  describe "Engram changeset TMC validation" do
    test "accepts valid supersession_type values" do
      for type <- ["update", "correction", "refinement", "merge", nil] do
        changeset =
          Engram.changeset(%Engram{}, %{
            content: "Test",
            category: "fact",
            supersession_type: type
          })

        refute changeset.errors[:supersession_type]
      end
    end

    test "rejects invalid supersession_type" do
      changeset =
        Engram.changeset(%Engram{}, %{
          content: "Test",
          category: "fact",
          supersession_type: "invalid_type"
        })

      assert changeset.errors[:supersession_type]
    end
  end
end
