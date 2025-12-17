defmodule Mimo.Brain.MemoryIntegratorTest do
  @moduledoc """
  Tests for Mimo.Brain.MemoryIntegrator.

  Tests the LLM-based memory integration decisions and execution.
  """

  use Mimo.DataCase, async: false

  alias Mimo.Brain.{MemoryIntegrator, Memory, Engram}
  alias Mimo.Repo

  # =============================================================================
  # Setup
  # =============================================================================

  setup do
    # Ensure TMC feature flag is enabled for tests
    original_flags = Application.get_env(:mimo_mcp, :feature_flags, [])
    new_flags = Keyword.put(original_flags, :temporal_memory_chains, true)
    Application.put_env(:mimo_mcp, :feature_flags, new_flags)

    on_exit(fn ->
      Application.put_env(:mimo_mcp, :feature_flags, original_flags)
    end)

    :ok
  end

  # Helper to create a memory using the correct API
  # Note: Use persist_memory/5 to get full engram (persist_memory/3 returns only ID)
  defp create_memory(content, category \\ "fact", importance \\ 0.5) do
    Memory.persist_memory(content, category, importance, nil, %{})
  end

  # =============================================================================
  # tmc_enabled?/0 Tests
  # =============================================================================

  describe "tmc_enabled?/0" do
    test "returns true when enabled via boolean" do
      original = Application.get_env(:mimo_mcp, :feature_flags, [])
      Application.put_env(:mimo_mcp, :feature_flags, temporal_memory_chains: true)

      assert MemoryIntegrator.tmc_enabled?() == true

      Application.put_env(:mimo_mcp, :feature_flags, original)
    end

    test "returns false when disabled" do
      original = Application.get_env(:mimo_mcp, :feature_flags, [])
      Application.put_env(:mimo_mcp, :feature_flags, temporal_memory_chains: false)

      assert MemoryIntegrator.tmc_enabled?() == false

      Application.put_env(:mimo_mcp, :feature_flags, original)
    end

    test "returns false when flag is missing" do
      original = Application.get_env(:mimo_mcp, :feature_flags, [])
      Application.put_env(:mimo_mcp, :feature_flags, [])

      assert MemoryIntegrator.tmc_enabled?() == false

      Application.put_env(:mimo_mcp, :feature_flags, original)
    end
  end

  # =============================================================================
  # decide/3 Tests
  # =============================================================================

  describe "decide/3" do
    test "returns :new when TMC is disabled" do
      original = Application.get_env(:mimo_mcp, :feature_flags, [])
      Application.put_env(:mimo_mcp, :feature_flags, temporal_memory_chains: false)

      existing = %Engram{
        id: 1,
        content: "Old content",
        category: "fact",
        inserted_at: DateTime.utc_now() |> DateTime.add(-86_400, :second)
      }

      result = MemoryIntegrator.decide("New content", existing, category: "fact")

      assert {:ok, %{decision: :new, reasoning: "TMC disabled"}} = result

      Application.put_env(:mimo_mcp, :feature_flags, original)
    end

    test "uses heuristic when LLM unavailable" do
      existing = %Engram{
        id: 1,
        content: "React 18 uses concurrent rendering",
        category: "fact",
        inserted_at:
          DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)
      }

      {:ok, result} =
        MemoryIntegrator.decide(
          "React 19 uses Server Components by default",
          existing,
          category: "fact"
        )

      # Should return a valid decision
      assert result.decision in [:update, :correction, :refinement, :redundant, :new]
      assert is_binary(result.reasoning)
    end

    test "handles map input for existing memory" do
      existing = %{
        id: 1,
        content: "Elixir 1.14 introduced dbg",
        category: "fact"
      }

      {:ok, result} =
        MemoryIntegrator.decide(
          "Elixir 1.18 introduces new features",
          existing,
          category: "fact"
        )

      assert result.decision in [:update, :correction, :refinement, :redundant, :new]
    end

    test "handles string-keyed map input" do
      existing = %{
        "id" => 1,
        "content" => "Phoenix 1.7 added LiveView",
        "category" => "fact"
      }

      {:ok, result} =
        MemoryIntegrator.decide(
          "Phoenix 1.8 adds verified routes",
          existing,
          category: "fact"
        )

      assert result.decision in [:update, :correction, :refinement, :redundant, :new]
    end
  end

  # =============================================================================
  # execute/4 Tests
  # =============================================================================

  describe "execute/4 with :new decision" do
    test "creates a new memory without supersession" do
      {:ok, engram} =
        MemoryIntegrator.execute(
          :new,
          "Completely new fact about testing",
          nil,
          category: "fact",
          importance: 0.7
        )

      assert engram.content == "Completely new fact about testing"
      assert engram.category == "fact"
      assert is_nil(engram.supersedes_id)
      assert is_nil(engram.superseded_at)
    end
  end

  describe "execute/4 with :redundant decision" do
    test "returns :skipped without creating memory" do
      # First create an existing memory
      {:ok, existing} = create_memory("Existing fact")

      result =
        MemoryIntegrator.execute(
          :redundant,
          "Same fact, different words",
          existing,
          category: "fact"
        )

      assert result == {:ok, :skipped}

      # Verify no new memory was created with this content
      memories = Repo.all(Engram)
      redundant_count = Enum.count(memories, &(&1.content == "Same fact, different words"))
      assert redundant_count == 0
    end
  end

  describe "execute/4 with :update decision" do
    test "creates new memory and supersedes old one" do
      # Create existing memory
      {:ok, existing} = create_memory("React 18 features", "fact", 0.7)

      {:ok, new_engram} =
        MemoryIntegrator.execute(
          :update,
          "React 19 features with Server Components",
          existing,
          category: "fact",
          importance: 0.7
        )

      # New memory should link to old
      assert new_engram.supersedes_id == existing.id
      assert new_engram.content == "React 19 features with Server Components"

      # Old memory should be marked as superseded
      old_refreshed = Repo.get!(Engram, existing.id)
      assert old_refreshed.superseded_at != nil
      assert old_refreshed.supersession_type == "update"
    end
  end

  describe "execute/4 with :correction decision" do
    test "creates correction chain" do
      {:ok, existing} = create_memory("Wrong information")

      {:ok, new_engram} =
        MemoryIntegrator.execute(
          :correction,
          "Corrected information",
          existing,
          category: "fact"
        )

      assert new_engram.supersedes_id == existing.id

      old_refreshed = Repo.get!(Engram, existing.id)
      assert old_refreshed.supersession_type == "correction"
    end
  end

  describe "execute/4 with :refinement decision" do
    test "merges content and creates chain" do
      {:ok, existing} = create_memory("Phoenix is a web framework")

      # Use :refinement which will attempt LLM merge, fall back to concat
      {:ok, new_engram} =
        MemoryIntegrator.execute(
          :refinement,
          "Phoenix supports real-time with LiveView",
          existing,
          category: "fact"
        )

      # Should have merged or concatenated content
      assert new_engram.supersedes_id == existing.id
      # Content should exist (either LLM merged or fallback)
      assert is_binary(new_engram.content)
      assert byte_size(new_engram.content) > 0

      old_refreshed = Repo.get!(Engram, existing.id)
      assert old_refreshed.supersession_type == "refinement"
    end
  end

  # =============================================================================
  # merge_content/3 Tests
  # =============================================================================

  describe "merge_content/3" do
    test "returns some content (LLM or fallback)" do
      result =
        MemoryIntegrator.merge_content(
          "Elixir is a functional language",
          "Elixir runs on the BEAM VM",
          category: "fact"
        )

      # May succeed or fail, but should not raise
      case result do
        {:ok, merged} ->
          assert is_binary(merged)
          assert byte_size(merged) > 0

        {:error, _reason} ->
          # LLM failure is acceptable in test environment
          :ok
      end
    end
  end

  # =============================================================================
  # supersede/3 Tests
  # =============================================================================

  describe "supersede/3" do
    test "marks engram as superseded" do
      {:ok, old_engram} = create_memory("Old fact")
      {:ok, new_engram} = create_memory("New fact")

      {:ok, updated} = MemoryIntegrator.supersede(old_engram, new_engram, :update)

      assert updated.superseded_at != nil
      assert updated.supersession_type == "update"
      assert updated.id == old_engram.id
    end

    test "supports different supersession types" do
      for type <- [:update, :correction, :refinement] do
        {:ok, old} = create_memory("Old #{type}")
        {:ok, new} = create_memory("New #{type}")

        {:ok, updated} = MemoryIntegrator.supersede(old, new, type)
        assert updated.supersession_type == to_string(type)
      end
    end
  end

  # =============================================================================
  # Integration Tests
  # =============================================================================

  describe "full integration flow" do
    test "decide then execute creates proper chain" do
      # Create initial memory
      {:ok, v1} = create_memory("PostgreSQL is a relational database", "fact", 0.8)

      # Decide on new content
      {:ok, decision} =
        MemoryIntegrator.decide(
          "PostgreSQL 16 adds new performance features",
          v1,
          category: "fact"
        )

      # Execute decision
      {:ok, result} =
        MemoryIntegrator.execute(
          decision.decision,
          "PostgreSQL 16 adds new performance features",
          v1,
          category: "fact",
          importance: 0.8
        )

      # Should have proper result
      case decision.decision do
        :redundant ->
          assert result == :skipped

        :new ->
          # New memory, no chain
          assert is_nil(result.supersedes_id)

        decision_type when decision_type in [:update, :correction, :refinement] ->
          # Should have chain
          assert result.supersedes_id == v1.id

          v1_refreshed = Repo.get!(Engram, v1.id)
          assert v1_refreshed.superseded_at != nil
      end
    end
  end

  # =============================================================================
  # Engram TMC Helper Integration
  # =============================================================================

  describe "Engram TMC helpers with persisted data" do
    test "active?/1 returns false for superseded engrams" do
      {:ok, old} = create_memory("Old")
      {:ok, new} = create_memory("New")

      {:ok, superseded} = MemoryIntegrator.supersede(old, new, :update)

      assert Engram.active?(superseded) == false
      assert Engram.superseded?(superseded) == true
    end

    test "has_predecessor?/1 works with supersedes_id" do
      {:ok, old} = create_memory("Original")

      {:ok, new} =
        MemoryIntegrator.execute(
          :update,
          "Updated version",
          old,
          category: "fact"
        )

      assert Engram.has_predecessor?(new) == true
      refute Engram.has_predecessor?(old)
    end

    test "chain_summary/1 returns a map with supersession info" do
      {:ok, old} = create_memory("V1")
      {:ok, new} = MemoryIntegrator.execute(:correction, "V2 corrected", old, category: "fact")

      summary = Engram.chain_summary(new)
      # chain_summary returns a map, not a string
      assert is_map(summary)
      assert summary.supersedes_id == old.id
    end
  end

  # =============================================================================
  # Edge Cases
  # =============================================================================

  describe "edge cases" do
    test "handles empty content gracefully" do
      {:ok, existing} = create_memory("Existing content")

      {:ok, decision} = MemoryIntegrator.decide("", existing, category: "fact")
      assert decision.decision in [:update, :correction, :refinement, :redundant, :new]
    end

    test "handles very long content" do
      long_content = String.duplicate("This is a long sentence. ", 100)
      {:ok, existing} = create_memory("Short content")

      {:ok, decision} = MemoryIntegrator.decide(long_content, existing, category: "fact")
      assert decision.decision in [:update, :correction, :refinement, :redundant, :new]
    end

    test "handles different categories" do
      {:ok, existing} = create_memory("An observation", "observation")

      {:ok, decision} =
        MemoryIntegrator.decide(
          "A related fact",
          existing,
          category: "fact"
        )

      # Cross-category should still work
      assert decision.decision in [:update, :correction, :refinement, :redundant, :new]
    end
  end
end
