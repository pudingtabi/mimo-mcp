defmodule Mimo.Repo.Migrations.AddBinaryEmbedding do
  @moduledoc """
  SPEC-033 Phase 3a: Add binary embedding column for fast Hamming pre-filtering.
  
  Binary embeddings use 1 bit per dimension (256 dim = 32 bytes).
  This enables O(1) Hamming distance computation for fast candidate filtering
  before more expensive cosine similarity calculations.
  """
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      # 32 bytes for 256-dim binary embedding
      # Can be populated from existing int8 embeddings via mix task
      add :embedding_binary, :binary
    end
    
    # Index on binary embedding for potential future optimizations
    # Note: SQLite doesn't have specialized binary indexes, but this
    # documents our intent and helps with some query patterns
    create index(:engrams, [:embedding_binary], where: "embedding_binary IS NOT NULL")
  end
end
