defmodule Mimo.SemanticStore.IngestorTest do
  use Mimo.DataCase, async: false

  alias Mimo.SemanticStore.{Ingestor, Repository}

  describe "ingest_triple/3" do
    test "ingests structured triple" do
      triple = %{
        subject: "auth service",
        predicate: "depends_on",
        object: "PostgreSQL"
      }

      assert {:ok, triple_id} = Ingestor.ingest_triple(triple, "test")
      assert is_binary(triple_id)
    end

    test "normalizes predicate" do
      triple = %{
        subject: "test",
        predicate: "Depends On",
        object: "other"
      }

      {:ok, _} = Ingestor.ingest_triple(triple, "test")

      # Check that predicate was normalized
      triples = Repository.get_by_predicate("depends_on")
      assert length(triples) >= 1
    end

    test "adds provenance to context" do
      triple = %{
        subject: "entity1",
        predicate: "relates_to",
        object: "entity2"
      }

      {:ok, id} = Ingestor.ingest_triple(triple, "my_source")

      stored = Repository.get(id)
      assert stored.context["source"] == "my_source"
      assert stored.context["method"] == "direct_ingestion"
    end
  end

  describe "ingest_batch/3" do
    test "ingests multiple triples" do
      triples = [
        %{subject: "a", predicate: "rel", object: "b"},
        %{subject: "b", predicate: "rel", object: "c"},
        %{subject: "c", predicate: "rel", object: "d"}
      ]

      assert {:ok, count} = Ingestor.ingest_batch(triples, "batch_test")
      assert count == 3
    end

    test "handles partial failures gracefully" do
      triples = [
        %{subject: "valid1", predicate: "rel", object: "valid2"},
        # May fail
        %{subject: "", predicate: "", object: ""},
        %{subject: "valid3", predicate: "rel", object: "valid4"}
      ]

      {:ok, count} = Ingestor.ingest_batch(triples, "test")
      assert count >= 2
    end
  end
end
