defmodule Mimo.Repo.Migrations.CreateNeuroSymbolicRules do
  use Ecto.Migration

  def change do
    create table(:neuro_symbolic_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :premise, :text, null: false
      add :conclusion, :text, null: false
      add :logical_form, :map, null: false
      add :confidence, :float, default: 0.5, null: false
      add :source, :string, null: false
      add :validation_status, :string, default: "pending"
      add :validation_evidence, :map, default: %{}
      add :usage_count, :integer, default: 0

      timestamps(type: :naive_datetime_usec)
    end

    create index(:neuro_symbolic_rules, [:confidence])
    create index(:neuro_symbolic_rules, [:validation_status])
  end
end
