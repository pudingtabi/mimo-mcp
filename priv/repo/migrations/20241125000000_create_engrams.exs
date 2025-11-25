defmodule Mimo.Repo.Migrations.CreateEngrams do
  use Ecto.Migration

  def change do
    create table(:engrams) do
      add :content, :text, null: false
      add :category, :string, size: 20, null: false
      add :importance, :float, default: 0.5, null: false
      # Store embedding as JSON text (SQLite doesn't support arrays natively)
      add :embedding, :text, default: "[]"
      # Store metadata as JSON text
      add :metadata, :text, default: "{}"
      
      timestamps()
    end

    create index(:engrams, [:category])
    create index(:engrams, [:importance])
    create index(:engrams, [:inserted_at])
  end
end
