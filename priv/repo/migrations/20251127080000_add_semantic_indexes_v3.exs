defmodule Mimo.Repo.Migrations.AddSemanticIndexesV3 do
  @moduledoc """
  CRITICAL: Adds composite indexes for O(log n) query performance.
  Without these indexes, all graph traversal operations are O(n).
  """
  use Ecto.Migration

  def change do
    # Primary SPO index (Subject-Predicate-Object)
    # Used by: transitive_closure, forward_chain, pattern_match
    create index(:semantic_triples, [:subject_id, :predicate, :object_id],
      name: :semantic_triples_spo_idx)

    # Reverse OSP index (Object-Subject-Predicate)  
    # Used by: backward_chain, get_by_object, incoming relationships
    create index(:semantic_triples, [:object_id, :subject_id, :predicate],
      name: :semantic_triples_osp_idx)

    # Predicate-only index for predicate-based queries
    # Used by: get_by_predicate, inference_engine
    create index(:semantic_triples, [:predicate],
      name: :semantic_triples_predicate_idx)

    # Entity anchor index for fast resolution
    # Used by: Resolver.search_entity_anchors
    create index(:engrams, [:category],
      where: "category = 'entity_anchor'",
      name: :engrams_entity_anchor_idx)

    # Note: graph_id index removed - column doesn't exist in semantic_triples table
    # If multi-tenant support is needed, add graph_id column to the table first
  end
end
