defmodule Mimo.SemanticStore.QueryTest do
  use Mimo.DataCase, async: false
  alias Mimo.SemanticStore.{Query, Repository}

  describe "transitive_closure/4" do
    test "finds multi-hop relationships" do
      # Insert test triples: Alice -> Bob -> CEO
      {:ok, _} =
        Repository.create(%{
          subject_id: "alice",
          subject_type: "person",
          predicate: "reports_to",
          object_id: "bob",
          object_type: "person",
          confidence: 1.0
        })

      {:ok, _} =
        Repository.create(%{
          subject_id: "bob",
          subject_type: "person",
          predicate: "reports_to",
          object_id: "ceo",
          object_type: "person",
          confidence: 1.0
        })

      results = Query.transitive_closure("alice", "person", "reports_to")

      assert length(results) >= 1
      ceo_result = Enum.find(results, &(&1.id == "ceo"))
      assert ceo_result != nil
      assert ceo_result.depth == 2
    end

    test "respects confidence threshold" do
      {:ok, _} =
        Repository.create(%{
          subject_id: "a",
          subject_type: "entity",
          predicate: "links_to",
          object_id: "b",
          object_type: "entity",
          # Below default threshold
          confidence: 0.5
        })

      results = Query.transitive_closure("a", "entity", "links_to", min_confidence: 0.7)
      assert results == []
    end

    test "respects max_depth limit" do
      # Create a chain: a -> b -> c -> d -> e
      for {from, to} <- [{"a", "b"}, {"b", "c"}, {"c", "d"}, {"d", "e"}] do
        Repository.create!(%{
          subject_id: from,
          subject_type: "node",
          predicate: "next",
          object_id: to,
          object_type: "node"
        })
      end

      results = Query.transitive_closure("a", "node", "next", max_depth: 2)

      # Should only reach b and c, not d or e
      ids = Enum.map(results, & &1.id)
      assert "b" in ids
      assert "c" in ids
      refute "d" in ids
      refute "e" in ids
    end
  end

  describe "pattern_match/1" do
    test "matches entities with multiple predicates" do
      # Alice reports to CEO and is located in SF
      Repository.create!(%{
        subject_id: "alice",
        subject_type: "person",
        predicate: "reports_to",
        object_id: "ceo",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "alice",
        subject_type: "person",
        predicate: "located_in",
        object_id: "sf",
        object_type: "city"
      })

      # Bob reports to CEO but is in NYC
      Repository.create!(%{
        subject_id: "bob",
        subject_type: "person",
        predicate: "reports_to",
        object_id: "ceo",
        object_type: "person"
      })

      Repository.create!(%{
        subject_id: "bob",
        subject_type: "person",
        predicate: "located_in",
        object_id: "nyc",
        object_type: "city"
      })

      # Find people who report to CEO AND are in SF
      results =
        Query.pattern_match([
          {:any, "reports_to", "ceo"},
          {:any, "located_in", "sf"}
        ])

      # Should find Alice but not Bob
      subject_ids = Enum.map(results, & &1.subject_id) |> Enum.uniq()
      assert "alice" in subject_ids
      refute "bob" in subject_ids
    end
  end

  describe "find_path/4" do
    test "finds shortest path between entities" do
      # Create: a -> b -> c and a -> d -> c (two paths)
      for {from, to} <- [{"a", "b"}, {"b", "c"}, {"a", "d"}, {"d", "c"}] do
        Repository.create!(%{
          subject_id: from,
          subject_type: "node",
          predicate: "connects_to",
          object_id: to,
          object_type: "node"
        })
      end

      {:ok, path} = Query.find_path("a", "c", "connects_to")

      # a -> ? -> c
      assert length(path) == 3
      assert hd(path) == "a"
      assert List.last(path) == "c"
    end

    test "returns error when no path exists" do
      Repository.create!(%{
        subject_id: "isolated",
        subject_type: "node",
        predicate: "connects_to",
        object_id: "nowhere",
        object_type: "node"
      })

      assert {:error, :no_path} = Query.find_path("isolated", "unreachable", "connects_to")
    end
  end
end
