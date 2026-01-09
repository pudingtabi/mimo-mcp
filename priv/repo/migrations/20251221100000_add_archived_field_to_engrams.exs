defmodule Mimo.Repo.Migrations.AddArchivedFieldToEngrams do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      # Archived memories are excluded from default search but not deleted
      # This implements archive-not-delete decay strategy for memory robustness
      add :archived, :boolean, default: false
      add :archived_at, :naive_datetime_usec
    end

    # Index for efficient filtering of archived memories
    create index(:engrams, [:archived], name: :engrams_archived_idx)
  end
end
