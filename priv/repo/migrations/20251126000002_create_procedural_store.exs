defmodule Mimo.Repo.Migrations.CreateProceduralStore do
  @moduledoc """
  Creates the procedural registry table for deterministic procedure execution.
  
  The Procedural Store enables deterministic execution of critical tasks
  using finite state machines, bypassing LLM generation for predictable outcomes.
  """
  use Ecto.Migration

  def change do
    create table(:procedural_registry, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :version, :string, null: false
      add :description, :text
      add :definition, :text, null: false        # JSON state machine definition
      add :hash, :string, null: false            # SHA256 for integrity verification
      add :active, :boolean, default: true
      add :rollback_procedure, :string           # Name of rollback procedure
      add :timeout_ms, :integer, default: 300_000  # Default 5 min timeout
      add :max_retries, :integer, default: 3
      add :metadata, :text, default: "{}"

      timestamps()
    end

    create unique_index(:procedural_registry, [:name, :version])
    create index(:procedural_registry, [:active, :name])
    create index(:procedural_registry, [:hash])

    # Execution history for audit and debugging
    create table(:procedure_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :procedure_id, references(:procedural_registry, type: :binary_id, on_delete: :nilify_all)
      add :procedure_name, :string, null: false
      add :procedure_version, :string, null: false
      add :status, :string, null: false          # pending, running, completed, failed, rolled_back
      add :current_state, :string
      add :context, :text, default: "{}"         # JSON execution context
      add :history, :text, default: "[]"         # JSON state transition history
      add :error, :text
      add :started_at, :naive_datetime_usec
      add :completed_at, :naive_datetime_usec
      add :duration_ms, :integer

      timestamps()
    end

    create index(:procedure_executions, [:procedure_id])
    create index(:procedure_executions, [:status])
    create index(:procedure_executions, [:started_at])
    create index(:procedure_executions, [:procedure_name, :procedure_version])
  end
end
