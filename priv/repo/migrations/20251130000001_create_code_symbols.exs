defmodule Mimo.Repo.Migrations.CreateCodeSymbols do
  @moduledoc """
  Creates the code_symbols table for SPEC-021 Living Codebase.

  This table stores extracted symbols (functions, classes, modules, etc.)
  from parsed source files.
  """
  use Ecto.Migration

  def change do
    create table(:code_symbols, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :file_path, :string, null: false
      add :name, :string, null: false
      add :qualified_name, :string  # Module.function for Elixir
      add :kind, :string, null: false  # function, class, module, method, variable
      add :language, :string, null: false  # elixir, python, javascript
      add :visibility, :string, default: "public"  # public, private
      add :start_line, :integer, null: false
      add :start_col, :integer, null: false
      add :end_line, :integer, null: false
      add :end_col, :integer, null: false
      add :parent_id, references(:code_symbols, type: :binary_id, on_delete: :nilify_all)
      add :signature, :string  # function signature for hover info
      add :doc, :text  # extracted documentation
      add :metadata, :map, default: %{}  # additional attributes
      add :file_hash, :string  # for detecting changes
      add :indexed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Fast lookups by file
    create index(:code_symbols, [:file_path])

    # Fast lookups by name (for "find symbol" queries)
    create index(:code_symbols, [:name])

    # Fast lookups by qualified name (for "go to definition")
    create index(:code_symbols, [:qualified_name])

    # Composite index for kind + language filtering
    create index(:code_symbols, [:kind, :language])

    # Index for parent relationships (for hierarchical queries)
    create index(:code_symbols, [:parent_id])

    # Unique constraint: one symbol per location
    create unique_index(:code_symbols, [:file_path, :start_line, :start_col, :name],
      name: :code_symbols_unique_location
    )
  end
end
