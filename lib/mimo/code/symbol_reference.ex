defmodule Mimo.Code.SymbolReference do
  @moduledoc """
  Ecto schema for code references (calls, imports, usages).

  References track where symbols are used throughout the codebase,
  enabling "find all references" and call graph analysis.
  This is part of SPEC-021 Living Codebase.

  ## Reference Kinds

  - `call` - Function/method call
  - `qualified_call` - Qualified call (Module.function)
  - `import` - Import statement
  - `alias` - Alias statement
  - `use` - Use statement (Elixir)
  - `require` - Require statement (Elixir)
  - `new` - Constructor call (new Class())
  - `extends` - Class inheritance
  - `implements` - Interface implementation

  ## Example

      # A function call reference
      %SymbolReference{
        name: "calculate_total",
        qualified_name: "MyApp.Orders.calculate_total",
        kind: "call",
        file_path: "/app/lib/my_app/checkout.ex",
        line: 87,
        col: 12,
        symbol_id: "uuid-of-the-target-function"
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @reference_kinds ~w(call qualified_call import alias use require new extends implements type_reference)
  @languages ~w(elixir python javascript typescript tsx)

  schema "symbol_references" do
    field(:file_path, :string)
    field(:name, :string)
    field(:qualified_name, :string)
    field(:kind, :string)
    field(:language, :string)
    field(:line, :integer)
    field(:col, :integer)
    field(:end_line, :integer)
    field(:end_col, :integer)
    field(:target_module, :string)
    field(:metadata, :map, default: %{})
    field(:file_hash, :string)

    # The symbol being referenced (resolved after indexing)
    belongs_to(:symbol, Mimo.Code.Symbol)

    # The symbol containing this reference (for scope analysis)
    belongs_to(:container, Mimo.Code.Symbol)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:file_path, :name, :kind, :language, :line, :col]
  @optional_fields [
    :qualified_name,
    :end_line,
    :end_col,
    :target_module,
    :metadata,
    :file_hash,
    :symbol_id,
    :container_id
  ]

  @doc """
  Creates a changeset for a symbol reference.
  """
  def changeset(reference, attrs) do
    reference
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @reference_kinds)
    |> validate_inclusion(:language, @languages)
    |> validate_number(:line, greater_than: 0)
    |> compute_qualified_name()
    |> foreign_key_constraint(:symbol_id)
    |> foreign_key_constraint(:container_id)
    |> unique_constraint([:file_path, :line, :col, :name],
      name: :symbol_references_unique_location
    )
  end

  @doc """
  Creates a new reference struct from parsed AST data.
  """
  def from_ast(ast_ref, file_path, language, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      file_path: file_path,
      name: ast_ref[:name],
      kind: ast_ref[:kind],
      language: language,
      line: ast_ref[:line],
      col: ast_ref[:col],
      end_line: ast_ref[:end_line],
      end_col: ast_ref[:end_col],
      target_module: ast_ref[:target_module],
      metadata: ast_ref[:metadata] || %{},
      file_hash: opts[:file_hash],
      container_id: opts[:container_id]
    })
  end

  @doc """
  Checks if this reference is a call (vs import/alias).
  """
  def call?(%__MODULE__{kind: kind}) do
    kind in ~w(call qualified_call new)
  end

  @doc """
  Checks if this reference is an import-like statement.
  """
  def import?(%__MODULE__{kind: kind}) do
    kind in ~w(import alias use require)
  end

  @doc """
  Returns a display string for the reference location.
  """
  def location_string(%__MODULE__{file_path: path, line: line, col: col}) do
    "#{path}:#{line}:#{col}"
  end

  # Private helpers

  defp compute_qualified_name(changeset) do
    case get_field(changeset, :qualified_name) do
      nil ->
        name = get_field(changeset, :name)
        target_module = get_field(changeset, :target_module)

        qualified =
          if target_module && target_module != "" do
            "#{target_module}.#{name}"
          else
            name
          end

        put_change(changeset, :qualified_name, qualified)

      _ ->
        changeset
    end
  end
end
