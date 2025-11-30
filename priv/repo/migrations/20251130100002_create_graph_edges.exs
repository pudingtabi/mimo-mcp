defmodule Mimo.Repo.Migrations.CreateGraphEdges do
  @moduledoc """
  Creates the graph_edges table for SPEC-023 Synapse Web.

  Graph edges represent typed relationships between nodes:
  - defines: File defines a Symbol
  - calls: Function calls another Function
  - imports: File imports a Module
  - uses: Symbol uses an ExternalLib
  - mentions: Memory mentions any entity
  - relates_to: Concept relates to another Concept
  - implements: Function implements a Concept
  - documented_by: Symbol documented by documentation node

  Edges have weights (0.0-1.0) for ranking and properties for metadata.
  """
  use Ecto.Migration

  def change do
    create table(:graph_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Source and target nodes
      add :source_node_id, references(:graph_nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :target_node_id, references(:graph_nodes, type: :binary_id, on_delete: :delete_all), null: false

      # Edge type
      add :edge_type, :string, null: false  # defines, calls, imports, uses, mentions, relates_to, implements, documented_by

      # Scoring
      add :weight, :float, default: 1.0  # Edge importance (0.0-1.0)
      add :confidence, :float, default: 1.0  # How confident we are in this edge

      # Properties
      add :properties, :map, default: %{}

      # Source tracking (how was this edge created?)
      add :source, :string  # static_analysis, semantic_inference, user_input, etc.

      # Access tracking for reinforcement
      add :last_accessed_at, :utc_datetime
      add :access_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    # Index for outgoing edges (traverse from a node)
    create index(:graph_edges, [:source_node_id])

    # Index for incoming edges (what points to this node)
    create index(:graph_edges, [:target_node_id])

    # Index for edge type filtering
    create index(:graph_edges, [:edge_type])

    # Index for weight-based queries (high-confidence edges first)
    create index(:graph_edges, [:weight])

    # Composite index for traversal queries
    create index(:graph_edges, [:source_node_id, :edge_type])

    # Unique constraint: one edge per (source, target, type) combination
    create unique_index(:graph_edges, [:source_node_id, :target_node_id, :edge_type],
      name: :graph_edges_unique_relationship
    )
  end
end
