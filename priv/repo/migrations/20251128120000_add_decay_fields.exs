defmodule Mimo.Repo.Migrations.AddDecayFields do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      add :access_count, :integer, default: 0
      add :last_accessed_at, :naive_datetime_usec
      add :decay_rate, :float, default: 0.1
      add :protected, :boolean, default: false
    end

    # Backfill last_accessed_at from inserted_at for existing records
    execute(
      "UPDATE engrams SET last_accessed_at = inserted_at WHERE last_accessed_at IS NULL",
      "SELECT 1"
    )

    # Index for efficient decay queries
    create index(:engrams, [:importance, :last_accessed_at, :protected],
             name: :engrams_decay_idx)

    # Index for access count queries
    create index(:engrams, [:access_count], name: :engrams_access_count_idx)
  end
end
