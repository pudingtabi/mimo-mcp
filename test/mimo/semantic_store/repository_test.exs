defmodule Mimo.SemanticStore.RepositoryTest do
  @moduledoc """
  Unit tests for Semantic Store Repository.

  SPEC-006: Validates CRUD operations, batch ingestion, and edge cases.
  """
  use Mimo.DataCase, async: false
  alias Mimo.SemanticStore.Repository

  describe "create/1" do
    test "creates a triple with valid attributes" do
      attrs = %{
        subject_id: "user:1",
        subject_type: "user",
        predicate: "knows",
        object_id: "user:2",
        object_type: "user",
        confidence: 0.9
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.subject_id == "user:1"
      assert triple.predicate == "knows"
      assert triple.object_id == "user:2"
      assert triple.confidence == 0.9
      assert triple.id != nil
    end

    test "creates triple with default confidence of 1.0" do
      attrs = %{
        subject_id: "a",
        subject_type: "entity",
        predicate: "links_to",
        object_id: "b",
        object_type: "entity"
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.confidence == 1.0
    end

    test "rejects confidence less than 0" do
      attrs = %{
        subject_id: "a",
        subject_type: "entity",
        predicate: "test",
        object_id: "c",
        object_type: "entity",
        confidence: -0.1
      }

      assert {:error, changeset} = Repository.create(attrs)
      assert errors_on(changeset)[:confidence] != nil
    end

    test "rejects confidence greater than 1" do
      attrs = %{
        subject_id: "a",
        subject_type: "entity",
        predicate: "test",
        object_id: "c",
        object_type: "entity",
        confidence: 1.5
      }

      assert {:error, changeset} = Repository.create(attrs)
      assert errors_on(changeset)[:confidence] != nil
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Repository.create(%{subject_id: "a"})
      errors = errors_on(changeset)
      assert errors[:subject_type] != nil
      assert errors[:predicate] != nil
      assert errors[:object_id] != nil
      assert errors[:object_type] != nil
    end

    test "creates triple with metadata" do
      attrs = %{
        subject_id: "entity:1",
        subject_type: "entity",
        predicate: "has_attr",
        object_id: "value:1",
        object_type: "value",
        metadata: %{"source" => "test", "priority" => 1}
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.metadata["source"] == "test"
      assert triple.metadata["priority"] == 1
    end

    test "creates triple with TTL" do
      attrs = %{
        subject_id: "temp:1",
        subject_type: "temp",
        predicate: "expires",
        object_id: "data:1",
        object_type: "data",
        ttl: 3600
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.ttl == 3600
    end

    test "rejects negative TTL" do
      attrs = %{
        subject_id: "a",
        subject_type: "entity",
        predicate: "test",
        object_id: "b",
        object_type: "entity",
        ttl: -100
      }

      assert {:error, changeset} = Repository.create(attrs)
      assert errors_on(changeset)[:ttl] != nil
    end
  end

  describe "upsert/1" do
    test "inserts new triple" do
      attrs = %{
        subject_id: "upsert:1",
        subject_type: "test",
        predicate: "test_pred",
        object_id: "target:1",
        object_type: "target"
      }

      assert {:ok, triple1} = Repository.upsert(attrs)
      assert triple1.id != nil
    end

    test "updates existing triple on conflict" do
      attrs = %{
        subject_id: "upsert:2",
        subject_type: "test",
        predicate: "test_pred",
        object_id: "target:2",
        object_type: "target",
        confidence: 0.5
      }

      {:ok, _triple1} = Repository.upsert(attrs)

      # Upsert with higher confidence
      {:ok, triple2} = Repository.upsert(Map.put(attrs, :confidence, 0.9))

      # Should have updated the confidence
      assert triple2.confidence == 0.9
    end
  end

  describe "batch_create/1" do
    test "creates multiple triples efficiently" do
      triples =
        for i <- 1..100 do
          %{
            subject_id: "batch:#{i}",
            subject_type: "batch",
            predicate: "test_relation",
            object_id: "target:#{rem(i, 10)}",
            object_type: "target"
          }
        end

      assert {:ok, count} = Repository.batch_create(triples)
      assert count == 100
    end

    test "handles empty list" do
      assert {:ok, 0} = Repository.batch_create([])
    end

    test "handles single element list" do
      triples = [
        %{
          subject_id: "single:1",
          subject_type: "test",
          predicate: "rel",
          object_id: "single:2",
          object_type: "test"
        }
      ]

      assert {:ok, 1} = Repository.batch_create(triples)
    end
  end

  describe "get/1" do
    test "retrieves triple by id" do
      {:ok, created} =
        Repository.create(%{
          subject_id: "get_test:1",
          subject_type: "test",
          predicate: "test",
          object_id: "get_test:2",
          object_type: "test"
        })

      retrieved = Repository.get(created.id)
      assert retrieved.id == created.id
      assert retrieved.subject_id == "get_test:1"
    end

    test "returns nil for non-existent id" do
      assert nil == Repository.get(Ecto.UUID.generate())
    end
  end

  describe "get_by_subject/2" do
    test "retrieves all triples for a subject" do
      # Create multiple triples for same subject
      for i <- 1..5 do
        Repository.create!(%{
          subject_id: "subj:test",
          subject_type: "test",
          predicate: "rel#{i}",
          object_id: "obj:#{i}",
          object_type: "obj"
        })
      end

      results = Repository.get_by_subject("subj:test", "test")
      assert length(results) == 5
    end

    test "returns empty list for non-existent subject" do
      results = Repository.get_by_subject("nonexistent", "type")
      assert results == []
    end
  end

  describe "get_by_predicate/2" do
    test "retrieves triples by predicate with confidence filter" do
      # Create triples with different confidences
      Repository.create!(%{
        subject_id: "pred_test:1",
        subject_type: "test",
        predicate: "special_pred",
        object_id: "obj:1",
        object_type: "obj",
        confidence: 0.9
      })

      Repository.create!(%{
        subject_id: "pred_test:2",
        subject_type: "test",
        predicate: "special_pred",
        object_id: "obj:2",
        object_type: "obj",
        confidence: 0.3
      })

      # Filter with min_confidence
      results = Repository.get_by_predicate("special_pred", min_confidence: 0.5)
      assert length(results) == 1
      assert hd(results).subject_id == "pred_test:1"
    end

    test "respects limit option" do
      for i <- 1..20 do
        Repository.create!(%{
          subject_id: "limit:#{i}",
          subject_type: "test",
          predicate: "limit_pred",
          object_id: "obj:#{i}",
          object_type: "obj"
        })
      end

      results = Repository.get_by_predicate("limit_pred", limit: 5)
      assert length(results) == 5
    end
  end

  describe "get_by_object/2" do
    test "retrieves all triples pointing to an object" do
      # Create triples pointing to same object
      for i <- 1..3 do
        Repository.create!(%{
          subject_id: "src:#{i}",
          subject_type: "source",
          predicate: "points_to",
          object_id: "common_target",
          object_type: "target"
        })
      end

      results = Repository.get_by_object("common_target", "target")
      assert length(results) == 3
    end
  end

  describe "update_confidence/2" do
    test "updates confidence for existing triple" do
      {:ok, triple} =
        Repository.create(%{
          subject_id: "conf_test:1",
          subject_type: "test",
          predicate: "test",
          object_id: "conf_test:2",
          object_type: "test",
          confidence: 0.5
        })

      assert {:ok, updated} = Repository.update_confidence(triple.id, 0.9)
      assert updated.confidence == 0.9
    end

    test "returns error for non-existent triple" do
      assert {:error, :not_found} = Repository.update_confidence(Ecto.UUID.generate(), 0.5)
    end
  end

  describe "delete/1" do
    test "deletes existing triple" do
      {:ok, triple} =
        Repository.create(%{
          subject_id: "del:1",
          subject_type: "test",
          predicate: "test",
          object_id: "del:2",
          object_type: "test"
        })

      assert {:ok, _} = Repository.delete(triple.id)
      assert nil == Repository.get(triple.id)
    end

    test "returns error for non-existent triple" do
      assert {:error, :not_found} = Repository.delete(Ecto.UUID.generate())
    end
  end

  describe "delete_by_subject/2" do
    test "deletes all triples for a subject" do
      for i <- 1..5 do
        Repository.create!(%{
          subject_id: "del_subj:test",
          subject_type: "del_type",
          predicate: "rel#{i}",
          object_id: "obj:#{i}",
          object_type: "obj"
        })
      end

      {count, _} = Repository.delete_by_subject("del_subj:test", "del_type")
      assert count == 5

      results = Repository.get_by_subject("del_subj:test", "del_type")
      assert results == []
    end
  end

  describe "search/2" do
    test "searches across subject, predicate, and object" do
      Repository.create!(%{
        subject_id: "search_alice",
        subject_type: "person",
        predicate: "knows",
        object_id: "search_bob",
        object_type: "person"
      })

      # Search by subject
      results = Repository.search("search_alice")
      assert results != []

      # Search by object
      results = Repository.search("search_bob")
      assert results != []

      # Search by predicate
      results = Repository.search("knows")
      assert results != []
    end

    test "respects min_confidence in search" do
      Repository.create!(%{
        subject_id: "search_low",
        subject_type: "test",
        predicate: "searchable",
        object_id: "target",
        object_type: "test",
        confidence: 0.3
      })

      results = Repository.search("search_low", min_confidence: 0.5)
      assert results == []

      results = Repository.search("search_low", min_confidence: 0.2)
      assert results != []
    end
  end

  describe "stats/0" do
    test "returns aggregate statistics" do
      # Create some test data
      Repository.create!(%{
        subject_id: "stats:1",
        subject_type: "test",
        predicate: "rel_a",
        object_id: "stats:2",
        object_type: "test"
      })

      Repository.create!(%{
        subject_id: "stats:3",
        subject_type: "test",
        predicate: "rel_b",
        object_id: "stats:4",
        object_type: "test"
      })

      stats = Repository.stats()

      assert stats.total_triples >= 2
      assert is_map(stats.by_predicate)
      assert is_float(stats.average_confidence)
    end
  end

  describe "store_triple/4" do
    test "stores triple with simplified API" do
      assert {:ok, _} = Repository.store_triple("alice", "knows", "bob")
    end

    test "stores triple with tuple entities" do
      assert {:ok, _} = Repository.store_triple({"alice", "person"}, "knows", {"bob", "person"})
    end

    test "stores triple with options" do
      assert {:ok, triple} =
               Repository.store_triple("alice", "trusts", "carol",
                 confidence: 0.8,
                 source: "manual"
               )

      assert triple.confidence == 0.8
      assert triple.source == "manual"
    end
  end

  describe "count_relationships/1" do
    test "counts both incoming and outgoing relationships" do
      # Create outgoing
      Repository.create!(%{
        subject_id: "count_center",
        subject_type: "node",
        predicate: "links",
        object_id: "out:1",
        object_type: "node"
      })

      Repository.create!(%{
        subject_id: "count_center",
        subject_type: "node",
        predicate: "links",
        object_id: "out:2",
        object_type: "node"
      })

      # Create incoming
      Repository.create!(%{
        subject_id: "in:1",
        subject_type: "node",
        predicate: "links",
        object_id: "count_center",
        object_type: "node"
      })

      count = Repository.count_relationships("count_center")
      assert count == 3
    end
  end

  describe "edge cases - Unicode and special characters" do
    test "handles Unicode entity IDs" do
      attrs = %{
        subject_id: "用户:张三",
        subject_type: "person",
        predicate: "knows",
        object_id: "用户:李四",
        object_type: "person"
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.subject_id == "用户:张三"
      assert triple.object_id == "用户:李四"
    end

    test "handles emoji in IDs" do
      attrs = %{
        subject_id: "project:🚀launch",
        subject_type: "project",
        predicate: "has_milestone",
        object_id: "milestone:🎯target",
        object_type: "milestone"
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.subject_id == "project:🚀launch"
    end

    test "handles special characters in predicates" do
      attrs = %{
        subject_id: "file:/path/to/file.txt",
        subject_type: "file",
        predicate: "depends_on",
        object_id: "lib:O'Brien-utils",
        object_type: "library"
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.object_id == "lib:O'Brien-utils"
    end

    test "handles Cyrillic characters" do
      attrs = %{
        subject_id: "пользователь:Иван",
        subject_type: "user",
        predicate: "работает_в",
        object_id: "компания:Техкорп",
        object_type: "company"
      }

      assert {:ok, triple} = Repository.create(attrs)
      assert triple.subject_id == "пользователь:Иван"
    end
  end
end
