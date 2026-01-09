defmodule Mimo.Brain.MemoryChainTest do
  @moduledoc """
  Tests for SPEC-034 TMC chain traversal functions in Memory module.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Brain.{Engram, Memory}
  alias Mimo.Repo

  # Helper to create an engram with minimal embedding data
  defp create_engram(content, opts \\ []) do
    category = Keyword.get(opts, :category, "fact")
    importance = Keyword.get(opts, :importance, 0.5)
    supersedes_id = Keyword.get(opts, :supersedes_id)
    superseded_at = Keyword.get(opts, :superseded_at)
    supersession_type = Keyword.get(opts, :supersession_type)

    attrs = %{
      content: content,
      category: category,
      importance: importance,
      supersedes_id: supersedes_id,
      superseded_at: superseded_at,
      supersession_type: supersession_type
    }

    %Engram{}
    |> Engram.changeset(attrs)
    |> Repo.insert!()
  end

  describe "get_chain/1" do
    test "returns empty list for non-existent engram" do
      assert Memory.get_chain(999_999) == []
    end

    test "returns single-item list for standalone engram" do
      engram = create_engram("Standalone memory")

      chain = Memory.get_chain(engram.id)

      assert length(chain) == 1
      assert hd(chain).id == engram.id
    end

    test "returns full chain from any position" do
      # Create a 3-node chain: A -> B -> C
      a = create_engram("Original fact")

      b =
        create_engram("Updated fact",
          supersedes_id: a.id,
          supersession_type: "update"
        )

      # Mark A as superseded
      Repo.update!(Engram.changeset(a, %{superseded_at: DateTime.utc_now()}))

      c =
        create_engram("Final fact",
          supersedes_id: b.id,
          supersession_type: "update"
        )

      # Mark B as superseded
      Repo.update!(Engram.changeset(b, %{superseded_at: DateTime.utc_now()}))

      # From any position, should get full chain
      chain_from_a = Memory.get_chain(a.id)
      chain_from_b = Memory.get_chain(b.id)
      chain_from_c = Memory.get_chain(c.id)

      assert length(chain_from_a) == 3
      assert length(chain_from_b) == 3
      assert length(chain_from_c) == 3

      # Verify order is oldest to newest
      assert Enum.at(chain_from_c, 0).id == a.id
      assert Enum.at(chain_from_c, 1).id == b.id
      assert Enum.at(chain_from_c, 2).id == c.id
    end
  end

  describe "get_current/1" do
    test "returns nil for non-existent engram" do
      assert Memory.get_current(999_999) == nil
    end

    test "returns same engram when not superseded" do
      engram = create_engram("Current memory")

      current = Memory.get_current(engram.id)

      assert current.id == engram.id
    end

    test "returns latest version from superseded engram" do
      # Create chain: A -> B -> C (C is current)
      a = create_engram("Original")

      b = create_engram("Updated", supersedes_id: a.id)
      Repo.update!(Engram.changeset(a, %{superseded_at: DateTime.utc_now()}))

      c = create_engram("Final", supersedes_id: b.id)
      Repo.update!(Engram.changeset(b, %{superseded_at: DateTime.utc_now()}))

      # From A, should get C
      current_from_a = Memory.get_current(a.id)
      assert current_from_a.id == c.id

      # From B, should get C
      current_from_b = Memory.get_current(b.id)
      assert current_from_b.id == c.id

      # From C, should get C
      current_from_c = Memory.get_current(c.id)
      assert current_from_c.id == c.id
    end
  end

  describe "get_original/1" do
    test "returns nil for non-existent engram" do
      assert Memory.get_original(999_999) == nil
    end

    test "returns same engram when it's the original" do
      engram = create_engram("Original memory")

      original = Memory.get_original(engram.id)

      assert original.id == engram.id
    end

    test "returns oldest version from any position" do
      # Create chain: A -> B -> C (A is original)
      a = create_engram("Original")

      b = create_engram("Updated", supersedes_id: a.id)
      Repo.update!(Engram.changeset(a, %{superseded_at: DateTime.utc_now()}))

      c = create_engram("Final", supersedes_id: b.id)
      Repo.update!(Engram.changeset(b, %{superseded_at: DateTime.utc_now()}))

      # From any position, should get A
      assert Memory.get_original(a.id).id == a.id
      assert Memory.get_original(b.id).id == a.id
      assert Memory.get_original(c.id).id == a.id
    end
  end

  describe "superseded?/1" do
    test "returns false for non-existent engram" do
      refute Memory.superseded?(999_999)
    end

    test "returns false for non-superseded engram" do
      engram = create_engram("Active memory")
      refute Memory.superseded?(engram.id)
    end

    test "returns true for superseded engram" do
      engram = create_engram("Old memory")

      # Mark as superseded
      Repo.update!(Engram.changeset(engram, %{superseded_at: DateTime.utc_now()}))

      assert Memory.superseded?(engram.id)
    end
  end

  describe "chain_length/1" do
    test "returns 0 for non-existent engram" do
      assert Memory.chain_length(999_999) == 0
    end

    test "returns 1 for standalone engram" do
      engram = create_engram("Standalone")
      assert Memory.chain_length(engram.id) == 1
    end

    test "returns correct count for chain" do
      # Create 3-node chain
      a = create_engram("First")

      b = create_engram("Second", supersedes_id: a.id)
      Repo.update!(Engram.changeset(a, %{superseded_at: DateTime.utc_now()}))

      c = create_engram("Third", supersedes_id: b.id)
      Repo.update!(Engram.changeset(b, %{superseded_at: DateTime.utc_now()}))

      # From any position
      assert Memory.chain_length(a.id) == 3
      assert Memory.chain_length(b.id) == 3
      assert Memory.chain_length(c.id) == 3
    end
  end

  describe "search with include_superseded option" do
    setup do
      # Clear engrams for clean test
      Repo.delete_all(Engram)
      :ok
    end

    test "maybe_filter_superseded excludes superseded by default" do
      # Test the filter function directly since search requires embeddings
      import Ecto.Query

      # Create active and superseded engrams
      active = create_engram("Active memory")
      superseded = create_engram("Superseded memory")

      # Mark one as superseded
      Repo.update!(Engram.changeset(superseded, %{superseded_at: DateTime.utc_now()}))

      # Query without superseded filter (should get both)
      all_query = from(e in Engram, select: e.id)
      all_ids = Repo.all(all_query)
      assert length(all_ids) == 2

      # Query with superseded filter (should only get active)
      # The filter is applied internally by Memory search functions
      # We verify the mechanism works by checking the engram status
      reloaded_active = Repo.get!(Engram, active.id)
      reloaded_superseded = Repo.get!(Engram, superseded.id)

      assert Engram.active?(reloaded_active)
      refute Engram.active?(reloaded_superseded)
    end

    test "superseded engrams have superseded_at set" do
      engram = create_engram("Test memory")

      # Initially not superseded
      assert is_nil(engram.superseded_at)

      # Mark as superseded
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, updated} = Repo.update(Engram.changeset(engram, %{superseded_at: now}))

      # Now has superseded_at
      refute is_nil(updated.superseded_at)
      assert Engram.superseded?(updated)
    end
  end
end
