defmodule Mimo.Repo.Migrations.AddKnowledgeSyncedAtToEngrams do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      add :knowledge_synced_at, :utc_datetime, null: true
    end

    # Index for efficient querying of unprocessed memories
    create index(:engrams, [:knowledge_synced_at], where: "knowledge_synced_at IS NULL")
  end
end
