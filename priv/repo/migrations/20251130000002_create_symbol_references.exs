defmodule Mimo.Repo.Migrations.CreateSymbolReferences do
  @moduledoc """
  Creates the symbol_references table for SPEC-021 Living Codebase.

  This table stores references (calls, imports, usages) to symbols,
  enabling "find all references" and call graph analysis.
  """
  use Ecto.Migration

  def change do
    create table(:symbol_references, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :file_path, :string, null: false  # File containing the reference
      add :name, :string, null: false  # Referenced name
      add :qualified_name, :string  # Full qualified name if available
      add :kind, :string, null: false  # call, import, alias, use, new, extends
      add :language, :string, null: false
      add :line, :integer, null: false
      add :col, :integer, null: false
      add :end_line, :integer
      add :end_col, :integer

      # Link to the symbol being referenced (if resolved)
      add :symbol_id, references(:code_symbols, type: :binary_id, on_delete: :nilify_all)

      # Link to the containing symbol (for scoped references)
      add :container_id, references(:code_symbols, type: :binary_id, on_delete: :nilify_all)

      # For qualified calls like Module.function
      add :target_module, :string

      add :metadata, :map, default: %{}
      add :file_hash, :string  # for detecting changes

      timestamps(type: :utc_datetime)
    end

    # Fast lookups by file (for incremental updates)
    create index(:symbol_references, [:file_path])

    # Fast lookups by name (for "find references")
    create index(:symbol_references, [:name])

    # Fast lookups by qualified name
    create index(:symbol_references, [:qualified_name])

    # Fast lookups by referenced symbol
    create index(:symbol_references, [:symbol_id])

    # Fast lookups by containing symbol
    create index(:symbol_references, [:container_id])

    # Composite index for kind + language filtering
    create index(:symbol_references, [:kind, :language])

    # Unique constraint: one reference per location
    create unique_index(:symbol_references, [:file_path, :line, :col, :name],
      name: :symbol_references_unique_location
    )
  end
end
