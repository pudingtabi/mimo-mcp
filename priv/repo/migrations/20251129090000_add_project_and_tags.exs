defmodule Mimo.Repo.Migrations.AddProjectAndTags do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      # Project/workspace scoping
      add :project_id, :string, default: "global"
      
      # Auto-generated tags (stored as JSON array)
      add :tags, :text, default: "[]"
    end

    # Index for project-scoped queries
    create index(:engrams, [:project_id])
    
    # Composite index for filtered searches
    create index(:engrams, [:project_id, :category])
  end
end
