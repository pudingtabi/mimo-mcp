defmodule Mimo.Repo.Migrations.CreateCrossModalityLinks do
  use Ecto.Migration

  def change do
    create table(:cross_modality_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_type, :string, null: false
      add :source_id, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :string, null: false
      add :link_type, :string, null: false
      add :confidence, :float, default: 0.5, null: false
      add :discovered_by, :string, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create index(:cross_modality_links, [:source_type, :source_id])
    create index(:cross_modality_links, [:target_type, :target_id])
  end
end
