defmodule Mimo.Repo.Migrations.EnhanceSemanticStoreV2 do
  use Ecto.Migration

  def change do
    alter table(:semantic_triples) do
      # JSON-LD context: provenance, confidence, timestamp
      # Example: %{"source" => "git_log", "confidence" => 0.9, "inferred" => false}
      add :context, :map, default: %{}
      
      # Multi-tenancy: "project:mimo", "user:alice", "global"
      add :graph_id, :string, default: "global"
      
      # Expiration: For "short-term" semantic facts that should fade
      add :expires_at, :utc_datetime
    end

    # Enable indexing for fast tenant lookups
    create index(:semantic_triples, [:graph_id])
  end
end
