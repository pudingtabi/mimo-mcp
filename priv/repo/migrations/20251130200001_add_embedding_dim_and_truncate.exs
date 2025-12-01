defmodule Mimo.Repo.Migrations.AddEmbeddingDimAndTruncate do
  @moduledoc """
  SPEC-031 Phase 1: MRL Truncation Migration

  Adds embedding_dim column to track embedding dimensions and truncates
  existing 1024-dim embeddings to 256-dim using MRL (Matryoshka Representation Learning).

  This is SAFE because qwen3-embedding supports MRL natively - the first N dimensions
  are optimized for reduced dimensionality, so no re-embedding is required.

  Storage savings: 4x reduction (1024 → 256 dimensions)
  Quality impact: <3% loss according to MRL research

  IMPORTANT: Back up the database before running this migration!
  """
  use Ecto.Migration

  @target_dim 256

  def up do
    # Step 1: Add embedding_dim column to track current dimension
    alter table(:engrams) do
      add :embedding_dim, :integer, default: 1024
    end

    # Create index for potential queries by dimension
    create index(:engrams, [:embedding_dim])

    # Step 2: Flush the alter to ensure column exists
    flush()

    # Step 3: Truncate existing embeddings from 1024 to 256 dimensions
    # This is safe due to MRL - the first N dimensions preserve semantic meaning
    # We use SQLite's JSON functions to truncate the array
    execute """
    UPDATE engrams
    SET 
      embedding = (
        SELECT json_group_array(value)
        FROM (
          SELECT value 
          FROM json_each(embedding) 
          LIMIT #{@target_dim}
        )
      ),
      embedding_dim = #{@target_dim},
      updated_at = datetime('now')
    WHERE json_array_length(embedding) > #{@target_dim}
    """
  end

  def down do
    # Cannot restore truncated dimensions - would need re-embedding with full 1024 dims
    # This down migration just removes the column
    drop_if_exists index(:engrams, [:embedding_dim])

    alter table(:engrams) do
      remove :embedding_dim
    end

    # Note: To fully restore 1024-dim embeddings, run:
    # mix mimo.reembed --dim 1024
  end
end
