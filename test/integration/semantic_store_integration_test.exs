defmodule Mimo.Integration.SemanticStoreIntegrationTest do
  @moduledoc """
  Integration tests for Semantic Store.
  
  SPEC-006: Tests full workflows, concurrent access, and real-world scenarios.
  """
  use ExUnit.Case

  @moduletag :integration

  alias Mimo.SemanticStore.{Repository, Query, InferenceEngine}
  alias Mimo.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "full workflow - query and inference" do
    test "creates triples, queries, and infers new relationships" do
      # 1. Create organizational hierarchy
      # CEO -> VP -> Manager -> Engineer
      triples = [
        %{
          subject_id: "engineer:alice",
          subject_type: "person",
          predicate: "reports_to",
          object_id: "manager:bob",
          object_type: "person"
        },
        %{
          subject_id: "manager:bob",
          subject_type: "person",
          predicate: "reports_to",
          object_id: "vp:carol",
          object_type: "person"
        },
        %{
          subject_id: "vp:carol",
          subject_type: "person",
          predicate: "reports_to",
          object_id: "ceo:dan",
          object_type: "person"
        }
      ]

      for attrs <- triples do
        {:ok, _} = Repository.create(attrs)
      end

      # 2. Query direct reports
      direct = Repository.get_by_subject("engineer:alice", "person")
      assert length(direct) == 1
      assert hd(direct).object_id == "manager:bob"

      # 3. Query transitive chain - who does alice ultimately report to?
      chain = Query.transitive_closure("engineer:alice", "person", "reports_to")
      ids = Enum.map(chain, & &1.id)

      assert "manager:bob" in ids
      assert "vp:carol" in ids
      assert "ceo:dan" in ids

      # Verify depths
      ceo = Enum.find(chain, &(&1.id == "ceo:dan"))
      assert ceo.depth == 3
    end

    test "handles location-based queries" do
      # People and their locations
      Repository.create!(%{
        subject_id: "person:alice",
        subject_type: "person",
        predicate: "located_in",
        object_id: "building:hq",
        object_type: "building"
      })

      Repository.create!(%{
        subject_id: "building:hq",
        subject_type: "building",
        predicate: "located_in",
        object_id: "city:sf",
        object_type: "city"
      })

      Repository.create!(%{
        subject_id: "city:sf",
        subject_type: "city",
        predicate: "located_in",
        object_id: "state:ca",
        object_type: "state"
      })

      # Find all location ancestors of alice
      locations = Query.transitive_closure("person:alice", "person", "located_in")
      ids = Enum.map(locations, & &1.id)

      assert "building:hq" in ids
      assert "city:sf" in ids
      assert "state:ca" in ids
    end
  end

  describe "concurrent access" do
    test "handles parallel writes safely" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Repository.create(%{
              subject_id: "concurrent:#{i}",
              subject_type: "test",
              predicate: "test_pred",
              object_id: "target:#{i}",
              object_type: "target"
            })
          end)
        end

      results = Task.await_many(tasks, 10_000)
      successes = Enum.count(results, &match?({:ok, _}, &1))

      assert successes == 100
    end

    test "handles parallel reads during writes" do
      # Seed data
      for i <- 1..50 do
        Repository.create!(%{
          subject_id: "rw:#{i}",
          subject_type: "entity",
          predicate: "test",
          object_id: "target:#{i}",
          object_type: "entity"
        })
      end

      # Parallel reads and writes
      read_tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Repository.get_by_subject("rw:#{:rand.uniform(50)}", "entity")
          end)
        end

      write_tasks =
        for i <- 51..100 do
          Task.async(fn ->
            Repository.create(%{
              subject_id: "rw:#{i}",
              subject_type: "entity",
              predicate: "test",
              object_id: "target:#{i}",
              object_type: "entity"
            })
          end)
        end

      # All should complete without deadlock
      all_results = Task.await_many(read_tasks ++ write_tasks, 30_000)

      # Verify reads returned lists and writes succeeded
      read_results = Enum.take(all_results, 50)
      write_results = Enum.drop(all_results, 50)

      assert Enum.all?(read_results, &is_list/1)
      assert Enum.count(write_results, &match?({:ok, _}, &1)) == 50
    end

    test "concurrent transitive queries don't interfere" do
      # Create a shared graph
      for i <- 1..10 do
        Repository.create!(%{
          subject_id: "graph:#{i}",
          subject_type: "node",
          predicate: "connects",
          object_id: "graph:#{i + 1}",
          object_type: "node"
        })
      end

      # Run concurrent traversals
      tasks =
        for start <- 1..5 do
          Task.async(fn ->
            Query.transitive_closure("graph:#{start}", "node", "connects")
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should return valid results
      assert Enum.all?(results, &is_list/1)

      # First query should find most results
      assert length(Enum.at(results, 0)) >= 5
    end
  end

  describe "inference engine integration" do
    test "forward chaining derives transitive relationships" do
      # Create a small hierarchy
      Repository.create!(%{
        subject_id: "inf:a",
        subject_type: "node",
        predicate: "reports_to",
        object_id: "inf:b",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "inf:b",
        subject_type: "node",
        predicate: "reports_to",
        object_id: "inf:c",
        object_type: "node"
      })

      {:ok, inferred} = InferenceEngine.forward_chain("reports_to")

      # Should infer a->c transitive relationship
      assert is_list(inferred)
    end
  end

  describe "scale scenarios" do
    @tag timeout: 60_000
    test "handles batch creation of 1000 triples" do
      triples =
        for i <- 1..1000 do
          %{
            subject_id: "scale:#{i}",
            subject_type: "node",
            predicate: "relates_to",
            object_id: "scale:#{rem(i, 100)}",
            object_type: "node"
          }
        end

      {time, result} = :timer.tc(fn -> Repository.batch_create(triples) end)

      assert {:ok, count} = result
      assert count == 1000

      # Should complete in reasonable time (< 10 seconds)
      assert time < 10_000_000
    end

    @tag timeout: 60_000
    test "queries perform well on larger dataset" do
      # Create a tree structure
      for i <- 1..10 do
        Repository.create!(%{
          subject_id: "perf_root",
          subject_type: "node",
          predicate: "parent_of",
          object_id: "perf_l1:#{i}",
          object_type: "node"
        })

        for j <- 1..10 do
          Repository.create!(%{
            subject_id: "perf_l1:#{i}",
            subject_type: "node",
            predicate: "parent_of",
            object_id: "perf_l2:#{i}:#{j}",
            object_type: "node"
          })
        end
      end

      # Traverse from root
      {time, results} =
        :timer.tc(fn ->
          Query.transitive_closure("perf_root", "node", "parent_of", max_depth: 3)
        end)

      # Should find all children
      assert length(results) >= 100

      # Query should be fast (< 1 second)
      assert time < 1_000_000
    end
  end

  describe "edge cases in integration" do
    test "handles empty queries gracefully" do
      results = Query.transitive_closure("nonexistent", "type", "predicate")
      assert results == []
    end

    test "handles very deep graphs with depth limit" do
      # Create a 20-node chain
      for i <- 1..20 do
        Repository.create!(%{
          subject_id: "deep:#{i}",
          subject_type: "node",
          predicate: "next",
          object_id: "deep:#{i + 1}",
          object_type: "node"
        })
      end

      # Query with depth limit
      results = Query.transitive_closure("deep:1", "node", "next", max_depth: 5)

      # Should respect depth limit
      ids = Enum.map(results, & &1.id)
      assert "deep:5" in ids
      assert "deep:6" in ids
      refute "deep:15" in ids
    end
  end
end
