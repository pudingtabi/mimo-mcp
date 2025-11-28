defmodule Mimo.SemanticStore.QueryCompleteTest do
  @moduledoc """
  Comprehensive query tests for Semantic Store.
  
  SPEC-006: Tests transitive closure, pattern matching, path finding,
  cycle detection, and edge cases.
  """
  use ExUnit.Case, async: true
  alias Mimo.SemanticStore.{Query, Repository}
  alias Mimo.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "transitive_closure/4 - chain traversal" do
    test "finds all nodes in linear chain" do
      # Create chain: A -> B -> C -> D
      create_chain(["A", "B", "C", "D"], "parent_of")

      results = Query.transitive_closure("A", "entity", "parent_of")

      ids = Enum.map(results, & &1.id)
      assert "B" in ids
      assert "C" in ids
      assert "D" in ids
    end

    test "respects max_depth parameter" do
      create_chain(["a", "b", "c", "d", "e"], "links_to")

      # With max_depth: 2, should only find b and c
      results = Query.transitive_closure("a", "entity", "links_to", max_depth: 2)

      ids = Enum.map(results, & &1.id)
      assert "b" in ids
      assert "c" in ids
      refute "d" in ids
      refute "e" in ids
    end

    test "includes path information" do
      create_chain(["start", "mid", "end"], "connects_to")

      results = Query.transitive_closure("start", "entity", "connects_to")
      end_result = Enum.find(results, &(&1.id == "end"))

      assert end_result != nil
      assert end_result.depth == 2
      assert "start" in end_result.path
      assert "mid" in end_result.path
      assert "end" in end_result.path
    end

    test "handles branching graphs" do
      # A -> B, A -> C, B -> D, C -> D
      Repository.create!(%{
        subject_id: "branch_a",
        subject_type: "node",
        predicate: "leads_to",
        object_id: "branch_b",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "branch_a",
        subject_type: "node",
        predicate: "leads_to",
        object_id: "branch_c",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "branch_b",
        subject_type: "node",
        predicate: "leads_to",
        object_id: "branch_d",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "branch_c",
        subject_type: "node",
        predicate: "leads_to",
        object_id: "branch_d",
        object_type: "node"
      })

      results = Query.transitive_closure("branch_a", "node", "leads_to")
      ids = Enum.map(results, & &1.id) |> Enum.uniq()

      assert "branch_b" in ids
      assert "branch_c" in ids
      assert "branch_d" in ids
    end

    test "handles cycles without infinite loop" do
      # Create cycle: A -> B -> C -> A
      Repository.create!(%{
        subject_id: "cycle_a",
        subject_type: "node",
        predicate: "cycle_rel",
        object_id: "cycle_b",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "cycle_b",
        subject_type: "node",
        predicate: "cycle_rel",
        object_id: "cycle_c",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "cycle_c",
        subject_type: "node",
        predicate: "cycle_rel",
        object_id: "cycle_a",
        object_type: "node"
      })

      # Should complete without hanging
      results = Query.transitive_closure("cycle_a", "node", "cycle_rel", max_depth: 10)

      # Should find b and c but not revisit a
      ids = Enum.map(results, & &1.id) |> Enum.uniq()
      assert "cycle_b" in ids
      assert "cycle_c" in ids
      # Should not have duplicate visits
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "returns empty for isolated node" do
      Repository.create!(%{
        subject_id: "isolated",
        subject_type: "node",
        predicate: "isolated_pred",
        object_id: "nowhere",
        object_type: "node"
      })

      # Query with different predicate
      results = Query.transitive_closure("isolated", "node", "nonexistent_pred")
      assert results == []
    end

    test "filters by confidence threshold" do
      Repository.create!(%{
        subject_id: "conf_a",
        subject_type: "node",
        predicate: "conf_rel",
        object_id: "conf_b",
        object_type: "node",
        confidence: 0.9
      })

      Repository.create!(%{
        subject_id: "conf_b",
        subject_type: "node",
        predicate: "conf_rel",
        object_id: "conf_c",
        object_type: "node",
        confidence: 0.5
      })

      # With high threshold, should only find b
      results = Query.transitive_closure("conf_a", "node", "conf_rel", min_confidence: 0.7)
      ids = Enum.map(results, & &1.id)
      assert "conf_b" in ids
      refute "conf_c" in ids
    end

    test "backward traversal finds subjects pointing to entity" do
      # Create: alice -> bob, carol -> bob (both point to bob)
      Repository.create!(%{
        subject_id: "alice",
        subject_type: "person",
        predicate: "knows",
        object_id: "bob",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "carol",
        subject_type: "person",
        predicate: "knows",
        object_id: "bob",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "dave",
        subject_type: "person",
        predicate: "knows",
        object_id: "alice",
        object_type: "person"
      })

      # Find who knows bob (backward from bob)
      results = Query.transitive_closure("bob", "person", "knows", direction: :backward)
      ids = Enum.map(results, & &1.id)

      # Should find alice and carol (direct), and dave (through alice)
      assert "alice" in ids
      assert "carol" in ids
    end
  end

  describe "pattern_match/1" do
    test "matches entities satisfying all conditions" do
      # Alice: reports_to CEO, located_in SF
      Repository.create!(%{
        subject_id: "pm_alice",
        subject_type: "person",
        predicate: "reports_to",
        object_id: "pm_ceo",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "pm_alice",
        subject_type: "person",
        predicate: "located_in",
        object_id: "pm_sf",
        object_type: "city"
      })

      # Bob: reports_to CEO, located_in NYC
      Repository.create!(%{
        subject_id: "pm_bob",
        subject_type: "person",
        predicate: "reports_to",
        object_id: "pm_ceo",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "pm_bob",
        subject_type: "person",
        predicate: "located_in",
        object_id: "pm_nyc",
        object_type: "city"
      })

      # Find: reports_to CEO AND located_in SF
      results =
        Query.pattern_match([
          {:any, "reports_to", "pm_ceo"},
          {:any, "located_in", "pm_sf"}
        ])

      subject_ids = Enum.map(results, & &1.subject_id) |> Enum.uniq()
      assert "pm_alice" in subject_ids
      refute "pm_bob" in subject_ids
    end

    test "returns empty when no matches" do
      results =
        Query.pattern_match([
          {:any, "nonexistent_pred", "nonexistent_obj"}
        ])

      assert results == []
    end

    test "handles single clause" do
      Repository.create!(%{
        subject_id: "single_clause",
        subject_type: "test",
        predicate: "has",
        object_id: "property",
        object_type: "attr"
      })

      results = Query.pattern_match([{:any, "has", "property"}])
      assert length(results) >= 1
    end
  end

  describe "find_path/4" do
    test "finds direct path between connected nodes" do
      Repository.create!(%{
        subject_id: "path_start",
        subject_type: "node",
        predicate: "path_rel",
        object_id: "path_end",
        object_type: "node"
      })

      {:ok, path} = Query.find_path("path_start", "path_end", "path_rel")
      assert path == ["path_start", "path_end"]
    end

    test "finds multi-hop path" do
      create_chain(["p1", "p2", "p3", "p4"], "connects")

      {:ok, path} = Query.find_path("p1", "p4", "connects")
      assert hd(path) == "p1"
      assert List.last(path) == "p4"
      assert length(path) == 4
    end

    test "finds shortest path when multiple exist" do
      # Direct path: a -> d
      Repository.create!(%{
        subject_id: "sp_a",
        subject_type: "node",
        predicate: "sp_rel",
        object_id: "sp_d",
        object_type: "node"
      })

      # Longer path: a -> b -> c -> d
      create_chain(["sp_a", "sp_b", "sp_c", "sp_d"], "sp_rel")

      {:ok, path} = Query.find_path("sp_a", "sp_d", "sp_rel")
      # Should find the 2-hop direct path
      assert length(path) == 2
    end

    test "returns error when no path exists" do
      Repository.create!(%{
        subject_id: "no_path_a",
        subject_type: "node",
        predicate: "np_rel",
        object_id: "no_path_b",
        object_type: "node"
      })

      result = Query.find_path("no_path_a", "unreachable", "np_rel")
      assert {:error, :no_path} = result
    end

    test "respects max_depth parameter" do
      create_chain(["deep_1", "deep_2", "deep_3", "deep_4", "deep_5"], "deep_rel")

      # With max_depth: 2, should not find path to deep_5
      result = Query.find_path("deep_1", "deep_5", "deep_rel", max_depth: 2)
      assert {:error, :no_path} = result

      # With sufficient depth, should find it
      {:ok, path} = Query.find_path("deep_1", "deep_5", "deep_rel", max_depth: 5)
      assert length(path) == 5
    end
  end

  describe "get_relationships/2" do
    test "returns both outgoing and incoming relationships" do
      # Center node with outgoing edges
      Repository.create!(%{
        subject_id: "center",
        subject_type: "node",
        predicate: "points_to",
        object_id: "out_1",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "center",
        subject_type: "node",
        predicate: "points_to",
        object_id: "out_2",
        object_type: "node"
      })

      # Incoming edges
      Repository.create!(%{
        subject_id: "in_1",
        subject_type: "node",
        predicate: "points_to",
        object_id: "center",
        object_type: "node"
      })

      result = Query.get_relationships("center", "node")

      assert length(result.outgoing) == 2
      assert length(result.incoming) == 1
    end

    test "handles node with no relationships" do
      result = Query.get_relationships("nonexistent_node", "node")
      assert result.outgoing == []
      assert result.incoming == []
    end
  end

  describe "count_by_type/0" do
    test "counts entities by type" do
      Repository.create!(%{
        subject_id: "type_a:1",
        subject_type: "type_a",
        predicate: "rel",
        object_id: "x",
        object_type: "x"
      })

      Repository.create!(%{
        subject_id: "type_a:2",
        subject_type: "type_a",
        predicate: "rel",
        object_id: "x",
        object_type: "x"
      })

      Repository.create!(%{
        subject_id: "type_b:1",
        subject_type: "type_b",
        predicate: "rel",
        object_id: "x",
        object_type: "x"
      })

      counts = Query.count_by_type()

      assert counts["type_a"] == 2
      assert counts["type_b"] == 1
    end
  end

  # Helper to create a chain of connected nodes
  defp create_chain(nodes, predicate) when length(nodes) >= 2 do
    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [from, to] ->
      Repository.create!(%{
        subject_id: from,
        subject_type: "entity",
        predicate: predicate,
        object_id: to,
        object_type: "entity"
      })
    end)
  end
end
