defmodule Mimo.Repo.Migrations.CreateAwakeningStats do
  @moduledoc """
  SPEC-040: Create awakening_stats table for power level tracking.
  
  This table stores XP, power levels, and achievements for the
  Mimo Awakening Protocol - transforming any AI into a memory-enhanced agent.
  """
  use Ecto.Migration

  def change do
    create table(:awakening_stats) do
      # Identifiers (optional, for multi-user support)
      add :user_id, :string
      add :project_id, :string
      
      # XP & Level
      add :total_xp, :integer, default: 0, null: false
      add :current_level, :integer, default: 1, null: false
      
      # Activity Metrics
      add :total_sessions, :integer, default: 0, null: false
      add :total_memories, :integer, default: 0, null: false
      add :total_relationships, :integer, default: 0, null: false
      add :total_procedures, :integer, default: 0, null: false
      add :total_tool_calls, :integer, default: 0, null: false
      
      # Timestamps
      add :first_awakening, :utc_datetime
      add :last_session, :utc_datetime
      
      # Achievements (JSON array of achievement IDs)
      add :achievements, {:array, :string}, default: []
      
      timestamps()
    end

    # Unique index for user+project combination
    create unique_index(:awakening_stats, [:user_id, :project_id])
    
    # Index for quick lookups by project
    create index(:awakening_stats, [:project_id])
  end
end
