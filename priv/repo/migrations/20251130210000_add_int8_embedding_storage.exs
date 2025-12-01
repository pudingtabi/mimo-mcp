defmodule Mimo.Repo.Migrations.AddInt8EmbeddingStorage do
  @moduledoc """
  SPEC-031 Phase 2: Add int8 quantized embedding storage fields.

  This migration adds three new columns to the engrams table:
  - embedding_int8: Binary blob containing quantized int8 values
  - embedding_scale: Scale factor for dequantization
  - embedding_offset: Offset for dequantization

  These fields enable 16x storage reduction compared to float32 JSON embeddings.

  Note: This migration adds the columns but does NOT migrate existing data.
  Use `mix mimo.quantize_embeddings` to convert existing float32 embeddings to int8.
  """
  use Ecto.Migration

  def up do
    # Add int8 embedding storage columns
    alter table(:engrams) do
      add :embedding_int8, :binary
      add :embedding_scale, :float
      add :embedding_offset, :float
    end

    # Add index for quick filtering of quantized vs non-quantized
    create index(:engrams, [:embedding_int8], where: "embedding_int8 IS NOT NULL")
  end

  def down do
    # Remove index first
    drop_if_exists index(:engrams, [:embedding_int8])

    # Remove columns
    alter table(:engrams) do
      remove :embedding_int8
      remove :embedding_scale
      remove :embedding_offset
    end
  end
end
