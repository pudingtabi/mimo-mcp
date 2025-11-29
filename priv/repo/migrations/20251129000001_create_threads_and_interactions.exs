defmodule Mimo.Repo.Migrations.CreateThreadsAndInteractions do
  use Ecto.Migration

  def change do
    # Threads: AI session tracking
    create table(:threads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, size: 255
      add :client_info, :map, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :last_active_at, :utc_datetime_usec, null: false
      add :status, :string, size: 20, null: false, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:status])
    create index(:threads, [:last_active_at])

    # Interactions: Raw tool call records (working memory)
    create table(:interactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all)
      add :tool_name, :string, size: 255, null: false
      add :arguments, :map, default: %{}
      add :result_summary, :text
      add :duration_ms, :integer
      add :timestamp, :utc_datetime_usec, null: false
      add :consolidated, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:interactions, [:thread_id])
    create index(:interactions, [:consolidated], where: "NOT consolidated")
    create index(:interactions, [:timestamp])

    # Link table: interactions -> engrams (for tracking which interactions created which memories)
    # Note: engrams use integer IDs (legacy), interactions use binary_id (new)
    create table(:interaction_engrams, primary_key: false) do
      add :interaction_id, references(:interactions, type: :binary_id, on_delete: :delete_all), primary_key: true
      add :engram_id, :integer, primary_key: true
    end

    create index(:interaction_engrams, [:engram_id])

    # SQLite doesn't support add_if_not_exists, so we use raw SQL with error handling
    # Add new columns to engrams for thread support
    execute """
    ALTER TABLE engrams ADD COLUMN original_importance REAL;
    """, ""

    execute """
    ALTER TABLE engrams ADD COLUMN thread_id TEXT;
    """, ""

    # Create index on thread_id
    execute """
    CREATE INDEX IF NOT EXISTS engrams_thread_id_index ON engrams(thread_id);
    """, ""

    # Backfill original_importance from importance
    execute """
    UPDATE engrams SET original_importance = importance WHERE original_importance IS NULL;
    """, ""
  end
end
