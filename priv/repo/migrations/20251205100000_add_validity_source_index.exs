defmodule Mimo.Repo.Migrations.AddValiditySourceIndexAndTemporalComposite do
  use Ecto.Migration

  @doc """
  SPEC-060 Enhancement: Add missing indexes for temporal validity queries.
  
  Addresses skeptical analysis finding: "No index on validity_source field causing table scans"
  
  Creates:
  1. Single-column index on validity_source for source-type filtering
  2. Composite index on (validity_source, valid_from, valid_until) for temporal + source queries
  """

  def change do
    # Index for filtering by validity source type (explicit, inferred, superseded, corrected)
    create_if_not_exists index(:engrams, [:validity_source], name: :idx_engrams_validity_source)
    
    # Composite index for queries that filter by source AND temporal bounds
    # Useful for queries like "find all explicitly-set facts valid at time X"
    create_if_not_exists index(:engrams, [:validity_source, :valid_from, :valid_until], 
      name: :idx_engrams_validity_source_temporal)
  end
end
