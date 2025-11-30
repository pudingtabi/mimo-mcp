defmodule Mimo.Code.Symbol do
  @moduledoc """
  Ecto schema for code symbols extracted from source files.

  Symbols represent named entities in code: functions, classes, modules,
  methods, variables, constants, etc. This is part of SPEC-021 Living Codebase.

  ## Symbol Kinds

  - `function` - Function or method definition
  - `class` - Class definition
  - `module` - Module definition (Elixir defmodule, Python module)
  - `method` - Method within a class (JS/TS/Python)
  - `variable` - Variable declaration
  - `constant` - Constant declaration (const in JS, @const in Elixir)
  - `import` - Import statement
  - `alias` - Alias statement (Elixir)
  - `use` - Use statement (Elixir)
  - `macro` - Macro definition (Elixir)

  ## Example

      # A function symbol
      %Symbol{
        name: "calculate_total",
        qualified_name: "MyApp.Orders.calculate_total",
        kind: "function",
        language: "elixir",
        visibility: "public",
        file_path: "/app/lib/my_app/orders.ex",
        start_line: 42,
        end_line: 55
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @symbol_kinds ~w(function class module method variable constant import alias use require macro)
  @languages ~w(elixir python javascript typescript tsx)
  @visibilities ~w(public private protected)

  schema "code_symbols" do
    field(:file_path, :string)
    field(:name, :string)
    field(:qualified_name, :string)
    field(:kind, :string)
    field(:language, :string)
    field(:visibility, :string, default: "public")
    field(:start_line, :integer)
    field(:start_col, :integer)
    field(:end_line, :integer)
    field(:end_col, :integer)
    field(:signature, :string)
    field(:doc, :string)
    field(:metadata, :map, default: %{})
    field(:file_hash, :string)
    field(:indexed_at, :utc_datetime)

    # Self-referential relationship for nested symbols
    belongs_to(:parent, __MODULE__)
    has_many(:children, __MODULE__, foreign_key: :parent_id)

    # References that point to this symbol
    has_many(:incoming_references, Mimo.Code.SymbolReference, foreign_key: :symbol_id)

    # References contained within this symbol's scope
    has_many(:contained_references, Mimo.Code.SymbolReference, foreign_key: :container_id)

    timestamps(type: :utc_datetime)
  end

  @required_fields [
    :file_path,
    :name,
    :kind,
    :language,
    :start_line,
    :start_col,
    :end_line,
    :end_col
  ]
  @optional_fields [
    :qualified_name,
    :visibility,
    :signature,
    :doc,
    :metadata,
    :file_hash,
    :indexed_at,
    :parent_id
  ]

  @doc """
  Creates a changeset for a symbol.
  """
  def changeset(symbol, attrs) do
    symbol
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @symbol_kinds)
    |> validate_inclusion(:language, @languages)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_number(:start_line, greater_than: 0)
    |> validate_number(:end_line, greater_than_or_equal_to: 0)
    |> compute_qualified_name()
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint([:file_path, :start_line, :start_col, :name],
      name: :code_symbols_unique_location
    )
  end

  @doc """
  Creates a new symbol struct from parsed AST data.
  """
  def from_ast(ast_symbol, file_path, language, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      file_path: file_path,
      name: ast_symbol[:name],
      kind: ast_symbol[:kind],
      language: language,
      visibility: ast_symbol[:visibility] || "public",
      start_line: ast_symbol[:start_line],
      start_col: ast_symbol[:start_col],
      end_line: ast_symbol[:end_line] || ast_symbol[:start_line],
      end_col: ast_symbol[:end_col] || 0,
      signature: ast_symbol[:signature],
      doc: ast_symbol[:doc],
      metadata: ast_symbol[:metadata] || %{},
      file_hash: opts[:file_hash],
      indexed_at: DateTime.utc_now(),
      parent_id: opts[:parent_id]
    })
  end

  @doc """
  Returns the display string for this symbol (for search results).
  """
  def display_name(%__MODULE__{qualified_name: qn}) when is_binary(qn) and qn != "", do: qn
  def display_name(%__MODULE__{name: name}), do: name

  @doc """
  Returns a human-readable description of the symbol.
  """
  def description(%__MODULE__{kind: kind, name: name, visibility: vis}) do
    vis_prefix = if vis == "private", do: "private ", else: ""
    "#{vis_prefix}#{kind} #{name}"
  end

  @doc """
  Checks if this symbol is a definition (vs an import/alias).
  """
  def definition?(%__MODULE__{kind: kind}) do
    kind in ~w(function class module method macro)
  end

  # Private helpers

  defp compute_qualified_name(changeset) do
    case get_field(changeset, :qualified_name) do
      nil ->
        # Auto-compute qualified name from parent context
        parent_id = get_field(changeset, :parent_id)
        name = get_field(changeset, :name)

        if parent_id && name do
          # Will be populated during indexing when parent is known
          changeset
        else
          put_change(changeset, :qualified_name, name)
        end

      _ ->
        changeset
    end
  end
end
