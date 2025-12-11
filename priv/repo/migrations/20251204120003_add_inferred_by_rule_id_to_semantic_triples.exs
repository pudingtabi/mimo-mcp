defmodule Mimo.Repo.Migrations.AddInferredByRuleIdToSemanticTriples do
  use Ecto.Migration

  def change do
    alter table(:semantic_triples) do
      add :inferred_by_rule_id, references(:neuro_symbolic_rules, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:semantic_triples, [:inferred_by_rule_id])
  end
end
