defmodule Mimo.Repo.Migrations.CreateGnnModels do
  use Ecto.Migration

  def change do
    create table(:gnn_models, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :integer, null: false
      add :trained_at, :utc_datetime
      add :embedding_dim, :integer
      add :accuracy, :float
      add :path, :string, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create index(:gnn_models, [:version])
  end
end
