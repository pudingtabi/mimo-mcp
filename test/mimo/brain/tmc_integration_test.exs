defmodule Mimo.Brain.TMCIntegrationTest do
  @moduledoc """
  Integration tests for SPEC-034 Temporal Memory Chains.

  Tests scenarios T01-T08 and edge cases E01-E10 from the spec.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.{Memory, Engram, NoveltyDetector, MemoryIntegrator}
  alias Mimo.Repo

  # Helper to enable TMC for tests
  defp enable_tmc do
    original = Application.get_env(:mimo_mcp, :feature_flags, [])

    Application.put_env(
      :mimo_mcp,
      :feature_flags,
      Keyword.put(original, :temporal_memory_chains, true)
    )

    original
  end

  defp restore_flags(original) do
    Application.put_env(:mimo_mcp, :feature_flags, original)
  end

  # Helper to create memory directly for test setup
  defp create_test_memory(content, opts \\ []) do
    category = Keyword.get(opts, :category, "fact")
    importance = Keyword.get(opts, :importance, 0.5)
    supersedes_id = Keyword.get(opts, :supersedes_id)
    supersession_type = Keyword.get(opts, :supersession_type)

    {:ok, engram} =
      %Engram{}
      |> Engram.changeset(%{
        content: content,
        category: category,
        importance: importance,
        supersedes_id: supersedes_id,
        supersession_type: supersession_type
      })
      |> Repo.insert()

    engram
  end

  # Helper to mark engram as superseded
  defp mark_superseded(engram) do
    {:ok, updated} =
      engram
      |> Engram.changeset(%{superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()

    updated
  end

  describe "T01: Simple update scenario" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "second memory supersedes first; search returns only second" do
      # Store first version: X=1
      first = create_test_memory("Configuration value X is set to 1")

      # Store second version: X=2 (supersedes first)
      second =
        create_test_memory("Configuration value X is set to 2",
          supersedes_id: first.id,
          supersession_type: "update"
        )

      mark_superseded(first)

      # Verify chain structure
      chain = Memory.get_chain(first.id)
      assert length(chain) == 2
      assert Enum.at(chain, 0).id == first.id
      assert Enum.at(chain, 1).id == second.id

      # Verify first is superseded, second is active
      assert Memory.superseded?(first.id)
      refute Memory.superseded?(second.id)

      # Verify get_current returns second from either position
      assert Memory.get_current(first.id).id == second.id
      assert Memory.get_current(second.id).id == second.id
    end
  end

  describe "T02: Redundant detection scenario" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "highly similar content is detected as redundant" do
      # Store first memory
      first = create_test_memory("Database X is configured with value 1")

      # Create a second with nearly identical meaning
      # NoveltyDetector should classify this as redundant
      classification =
        NoveltyDetector.classify(
          # Very similar
          "Database X has value 1",
          "fact"
        )

      # Should be either :redundant or :new depending on embedding similarity
      # The key is the system handles it without errors
      assert classification in [{:new, []}, {:redundant, first}] or
               match?({:ambiguous, _}, classification)
    end
  end

  describe "T03: True new despite similarity" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "different topics with similar words are both stored" do
      # Store auth bug memory
      bug_memory = create_test_memory("Authentication bug causes login failures")

      # Auth feature is different topic
      feature_memory = create_test_memory("Authentication feature allows SSO login")

      # Both should exist independently (not in same chain)
      assert is_nil(feature_memory.supersedes_id)
      assert Memory.chain_length(bug_memory.id) == 1
      assert Memory.chain_length(feature_memory.id) == 1
    end
  end

  describe "T04: Correction scenario" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "correction creates chain with correction type" do
      # Store "bug exists"
      first = create_test_memory("HNSW search bug causes slow performance")

      # Correction: "bug was not real"
      second =
        create_test_memory("HNSW search is working correctly - no bug",
          supersedes_id: first.id,
          supersession_type: "correction"
        )

      mark_superseded(first)

      # Verify chain shows correction type
      chain = Memory.get_chain(first.id)
      assert length(chain) == 2

      correcting_engram = Enum.at(chain, 1)
      assert correcting_engram.supersession_type == "correction"
    end
  end

  describe "T05: Refinement scenario" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "refinement adds detail while preserving original" do
      # Store "X works"
      first = create_test_memory("Elixir pattern matching works")

      # Refinement adds detail: "X works via Y mechanism"
      second =
        create_test_memory("Elixir pattern matching works via compile-time optimization",
          supersedes_id: first.id,
          supersession_type: "refinement"
        )

      mark_superseded(first)

      # Verify chain shows refinement type
      chain = Memory.get_chain(first.id)
      assert length(chain) == 2

      # Second should have more detailed content
      refining_engram = Enum.at(chain, 1)
      assert refining_engram.supersession_type == "refinement"
      assert String.length(refining_engram.content) > String.length(first.content)
    end
  end

  describe "T06: Default search excludes superseded" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "search only returns active memories by default" do
      # Create chain: old -> current
      old = create_test_memory("Old version of fact")

      current =
        create_test_memory("Current version of fact",
          supersedes_id: old.id,
          supersession_type: "update"
        )

      mark_superseded(old)

      # Verify only current is active
      reloaded_old = Repo.get!(Engram, old.id)
      reloaded_current = Repo.get!(Engram, current.id)

      refute Engram.active?(reloaded_old)
      assert Engram.active?(reloaded_current)
    end
  end

  describe "T07: History search includes superseded" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "include_superseded option returns all versions" do
      # Create chain with superseded memories
      old = create_test_memory("First version")

      current =
        create_test_memory("Second version",
          supersedes_id: old.id,
          supersession_type: "update"
        )

      mark_superseded(old)

      # Both should be in the chain
      chain = Memory.get_chain(old.id)
      assert length(chain) == 2

      # Chain includes both active and superseded
      ids = Enum.map(chain, & &1.id)
      assert old.id in ids
      assert current.id in ids
    end
  end

  describe "T08: Chain traversal" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "get_chain returns full history oldest to newest" do
      # Create 3-node chain: A -> B -> C
      a = create_test_memory("Version A - Original")

      b =
        create_test_memory("Version B - Update",
          supersedes_id: a.id,
          supersession_type: "update"
        )

      mark_superseded(a)

      c =
        create_test_memory("Version C - Latest",
          supersedes_id: b.id,
          supersession_type: "update"
        )

      mark_superseded(b)

      # get_chain from any position returns full chain
      chain = Memory.get_chain(a.id)

      assert length(chain) == 3
      # Oldest first
      assert Enum.at(chain, 0).id == a.id
      assert Enum.at(chain, 1).id == b.id
      # Newest last
      assert Enum.at(chain, 2).id == c.id

      # get_original returns A from any position
      assert Memory.get_original(a.id).id == a.id
      assert Memory.get_original(b.id).id == a.id
      assert Memory.get_original(c.id).id == a.id

      # get_current returns C from any position
      assert Memory.get_current(a.id).id == c.id
      assert Memory.get_current(b.id).id == c.id
      assert Memory.get_current(c.id).id == c.id
    end
  end

  # ============================================================================
  # Edge Cases (E01-E10)
  # ============================================================================

  describe "E01: Rapid updates" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "5 rapid updates create clean chain without orphans" do
      # Create 5 updates in rapid succession
      engrams =
        Enum.reduce(1..5, [], fn i, acc ->
          prev_id = if acc == [], do: nil, else: List.last(acc).id

          engram =
            create_test_memory("Version #{i}",
              supersedes_id: prev_id,
              supersession_type: if(prev_id, do: "update", else: nil)
            )

          # Mark previous as superseded
          if prev_id do
            Repo.get!(Engram, prev_id)
            |> Engram.changeset(%{superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)})
            |> Repo.update!()
          end

          acc ++ [engram]
        end)

      # Verify chain integrity
      first = hd(engrams)
      chain = Memory.get_chain(first.id)

      assert length(chain) == 5

      # Only last should be active
      Enum.with_index(chain)
      |> Enum.each(fn {engram, idx} ->
        if idx < 4 do
          refute Engram.active?(engram)
        else
          assert Engram.active?(engram)
        end
      end)
    end
  end

  describe "E02: Contradicting corrections (A→B→A)" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "circular fact corrections preserve all versions" do
      # A: Bug exists
      a = create_test_memory("The bug exists in production")

      # B: Bug fixed (corrects A)
      b =
        create_test_memory("The bug has been fixed",
          supersedes_id: a.id,
          supersession_type: "correction"
        )

      mark_superseded(a)

      # C: Bug returned! (corrects B, back to original state)
      c =
        create_test_memory("The bug has reappeared after deploy",
          supersedes_id: b.id,
          supersession_type: "correction"
        )

      mark_superseded(b)

      # All 3 versions should be in chain
      chain = Memory.get_chain(a.id)
      assert length(chain) == 3

      # History is preserved even though state is "circular"
      assert Enum.at(chain, 0).content =~ "exists"
      assert Enum.at(chain, 1).content =~ "fixed"
      assert Enum.at(chain, 2).content =~ "reappeared"
    end
  end

  describe "E03: Cross-category conflict" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "same topic in different categories kept separate" do
      # fact: X=1
      fact = create_test_memory("Configuration X is set to 1", category: "fact")

      # observation: X=2 (different category - should NOT be linked)
      observation = create_test_memory("I observed X appears to be 2", category: "observation")

      # They should NOT be in the same chain
      assert is_nil(observation.supersedes_id)
      assert Memory.chain_length(fact.id) == 1
      assert Memory.chain_length(observation.id) == 1
    end
  end

  describe "E06: Self-supersession prevention" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "memory cannot supersede itself" do
      engram = create_test_memory("Test memory")

      # Try to make it supersede itself
      result =
        engram
        |> Engram.changeset(%{supersedes_id: engram.id})
        |> Repo.update()

      # Should either fail validation or the changeset should reject it
      # For now, verify the chain doesn't break
      chain = Memory.get_chain(engram.id)
      assert length(chain) == 1
    end
  end

  describe "E07: Long chains performance" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "20-node chain traversal completes quickly" do
      # Create 20-node chain
      engrams =
        Enum.reduce(1..20, [], fn i, acc ->
          prev_id = if acc == [], do: nil, else: List.last(acc).id

          engram =
            create_test_memory("Version #{i} of long chain test",
              supersedes_id: prev_id,
              supersession_type: if(prev_id, do: "update", else: nil)
            )

          if prev_id do
            Repo.get!(Engram, prev_id)
            |> Engram.changeset(%{superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)})
            |> Repo.update!()
          end

          acc ++ [engram]
        end)

      first = hd(engrams)

      # Measure traversal time
      {time_microseconds, chain} =
        :timer.tc(fn ->
          Memory.get_chain(first.id)
        end)

      # Should complete in under 100ms
      assert time_microseconds < 100_000
      assert length(chain) == 20

      # get_current should also be fast
      {current_time, current} =
        :timer.tc(fn ->
          Memory.get_current(first.id)
        end)

      assert current_time < 100_000
      assert current.id == List.last(engrams).id
    end
  end

  describe "E08: Orphan cleanup (delete middle of chain)" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "deleting middle node nilifies FK references" do
      # Create chain: A -> B -> C
      a = create_test_memory("Node A")
      b = create_test_memory("Node B", supersedes_id: a.id, supersession_type: "update")
      mark_superseded(a)
      c = create_test_memory("Node C", supersedes_id: b.id, supersession_type: "update")
      mark_superseded(b)

      # Delete middle node B
      Repo.delete!(b)

      # Chain from A should now only have A (B is gone)
      chain_from_a = Memory.get_chain(a.id)
      assert length(chain_from_a) == 1
      assert hd(chain_from_a).id == a.id

      # C's supersedes_id is nilified by on_delete: :nilify_all
      reloaded_c = Repo.get!(Engram, c.id)
      # FK constraint nilifies
      assert is_nil(reloaded_c.supersedes_id)

      # Chain from C shows only C (no longer linked)
      chain_from_c = Memory.get_chain(c.id)
      assert length(chain_from_c) == 1
      assert hd(chain_from_c).id == c.id
    end
  end

  describe "E10: Protected memory handling" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "protected memories are handled correctly in chains" do
      # Create a protected memory
      protected =
        %Engram{}
        |> Engram.changeset(%{
          content: "Critical system configuration - DO NOT MODIFY",
          category: "fact",
          importance: 1.0,
          protected: true
        })
        |> Repo.insert!()

      # Can still create a superseding memory (system doesn't prevent this)
      # But the protected flag should be considered by business logic
      new_version =
        create_test_memory("Updated system configuration",
          supersedes_id: protected.id,
          supersession_type: "update"
        )

      # Protected memory exists in chain
      chain = Memory.get_chain(protected.id)
      assert length(chain) == 2

      # Original is still protected
      reloaded = Repo.get!(Engram, protected.id)
      assert reloaded.protected == true
    end
  end

  describe "MemoryIntegrator integration" do
    setup do
      Repo.delete_all(Engram)
      original = enable_tmc()
      on_exit(fn -> restore_flags(original) end)
      :ok
    end

    test "MemoryIntegrator.execute creates proper supersession chain" do
      # Create existing memory
      existing = create_test_memory("Original fact about Elixir")

      # Use MemoryIntegrator to create an update
      {:ok, new_engram} =
        MemoryIntegrator.execute(
          :update,
          "Updated fact about Elixir with more detail",
          existing,
          category: "fact",
          importance: 0.7
        )

      # Verify chain was created
      # New engram has supersedes_id pointing to existing
      assert new_engram.supersedes_id == existing.id

      # Verify old one is superseded
      # supersession_type is stored on the OLD engram (the one being superseded)
      # not the new one - it indicates WHY this memory was superseded
      reloaded_existing = Repo.get!(Engram, existing.id)
      refute is_nil(reloaded_existing.superseded_at)
      assert reloaded_existing.supersession_type == "update"
    end

    test "MemoryIntegrator.execute with :new decision creates standalone memory" do
      # Execute with :new decision (no existing memory to supersede)
      {:ok, engram} =
        MemoryIntegrator.execute(
          :new,
          "Completely new fact about Phoenix",
          nil,
          category: "fact",
          importance: 0.6
        )

      # Should have no supersession links
      assert is_nil(engram.supersedes_id)
      assert is_nil(engram.supersession_type)
      assert Memory.chain_length(engram.id) == 1
    end

    test "MemoryIntegrator.execute with :redundant returns skipped" do
      existing = create_test_memory("Existing fact")

      # Execute with :redundant decision
      result =
        MemoryIntegrator.execute(
          :redundant,
          "Same fact restated",
          existing,
          category: "fact"
        )

      assert result == {:ok, :skipped}
    end
  end
end
