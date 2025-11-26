defmodule Mimo.Repo.Migrations.CreateSemanticStore do
  @moduledoc """
  Creates the semantic triples table for the Semantic Store.
  
  The Semantic Store provides exact relationship storage as Subject-Predicate-Object
  triples, enabling multi-hop graph traversal and deterministic fact queries.
  """
  use Ecto.Migration

  def change do
    create table(:semantic_triples, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_hash, :string, null: false  # MD5(subject_id:subject_type) for indexing
      add :subject_id, :string, null: false    # Entity identifier
      add :subject_type, :string, null: false  # e.g., "person", "company"
      add :predicate, :string, null: false     # Relationship verb
      add :object_id, :string, null: false     # Target entity ID
      add :object_type, :string, null: false   # e.g., "role", "location"
      add :confidence, :float, default: 1.0    # Fact certainty [0.0, 1.0]
      add :source, :string                     # Provenance/origin
      add :ttl, :integer                       # Time-to-live in seconds (nil = permanent)
      add :metadata, :text, default: "{}"      # JSON metadata

      timestamps(type: :naive_datetime_usec)
    end

    # Covering indexes for all SPO (Subject-Predicate-Object) access patterns
    # SPO: Find all facts about a subject with a specific predicate
    create index(:semantic_triples, [:subject_hash, :predicate, :object_id],
             name: :semantic_spo_index)

    # POS: Find all subjects with a predicate pointing to an object
    create index(:semantic_triples, [:predicate, :object_id, :subject_hash],
             name: :semantic_pos_index)

    # OSP: Find all subjects connected to an object
    create index(:semantic_triples, [:object_id, :subject_hash, :predicate],
             name: :semantic_osp_index)

    # Partial index for high-confidence facts only
    create index(:semantic_triples, [:subject_hash, :predicate],
             where: "confidence >= 0.9",
             name: :semantic_confident_facts_index)

    # Index for TTL-based cleanup
    create index(:semantic_triples, [:inserted_at],
             where: "ttl IS NOT NULL",
             name: :semantic_ttl_cleanup_index)

    # Unique constraint to prevent duplicate triples
    create unique_index(:semantic_triples, 
             [:subject_hash, :predicate, :object_id, :object_type],
             name: :semantic_unique_triple_index)
  end
end
