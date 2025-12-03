defmodule Mimo.Repo.Migrations.CreateEmergencePatterns do
  use Ecto.Migration

  def change do
    create table(:emergence_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      
      # Pattern classification
      add :type, :string, null: false  # workflow, inference, heuristic, skill
      add :description, :text, null: false
      add :signature, :string  # For deduplication
      
      # Pattern components (JSON arrays)
      add :components, :text, default: "[]"  # JSON list of component definitions
      add :trigger_conditions, :text, default: "[]"  # JSON list of conditions
      
      # Metrics
      add :success_rate, :float, default: 0.0
      add :occurrences, :integer, default: 1
      add :strength, :float, default: 0.0
      
      # Timestamps
      add :first_seen, :utc_datetime_usec
      add :last_seen, :utc_datetime_usec
      
      # Evolution tracking (JSON list of snapshots)
      add :evolution, :text, default: "[]"
      
      # Status
      add :status, :string, default: "active"  # active, promoted, dormant, archived
      
      # Additional metadata (JSON)
      add :metadata, :text, default: "{}"
      
      timestamps(type: :utc_datetime_usec)
    end
    
    # Indexes for common queries
    create index(:emergence_patterns, [:type])
    create index(:emergence_patterns, [:status])
    create index(:emergence_patterns, [:strength])
    create index(:emergence_patterns, [:signature], unique: true)
    create index(:emergence_patterns, [:first_seen])
    create index(:emergence_patterns, [:last_seen])
    
    # Composite index for pattern discovery
    create index(:emergence_patterns, [:type, :status, :strength])
  end
end
