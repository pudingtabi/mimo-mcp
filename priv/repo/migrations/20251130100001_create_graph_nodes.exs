defmodule Mimo.Repo.Migrations.CreateGraphNodes do
  @moduledoc """
  Creates the graph_nodes table for SPEC-023 Synapse Web.

  Graph nodes represent typed entities in the knowledge graph:
  - Concept: abstract ideas and categories
  - File: source files in the codebase
  - Function: functions, methods, procedures
  - Module: modules, classes, namespaces
  - ExternalLib: external library packages
  - Memory: memory engrams

  Each node can have properties (JSON), embeddings for vector search,
  and references back to source entities (code symbols, engrams, etc.)
  """
  use Ecto.Migration

  def change do
    # Create enum type for node types (SQLite handles this as string)
    create table(:graph_nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Core fields
      add :node_type, :string, null: false  # concept, file, function, module, external_lib, memory
      add :name, :string, null: false
      add :properties, :map, default: %{}

      # Vector embedding for similarity search
      add :embedding, :text  # JSON serialized float array

      # References to source entities
      add :source_ref_type, :string  # code_symbol, engram, package, etc.
      add :source_ref_id, :string    # ID in source table

      # Metadata
      add :description, :text
      add :last_accessed_at, :utc_datetime
      add :access_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    # Index for type-based queries
    create index(:graph_nodes, [:node_type])

    # Index for name searches
    create index(:graph_nodes, [:name])

    # Composite unique index: one node per type+name combination
    create unique_index(:graph_nodes, [:node_type, :name],
      name: :graph_nodes_unique_type_name
    )

    # Index for source reference lookups
    create index(:graph_nodes, [:source_ref_type, :source_ref_id])
  end
end
