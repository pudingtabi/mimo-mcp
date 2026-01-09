defmodule Mimo.Code.TreeSitter do
  alias Mimo.Code.TreeSitter.Native

  @moduledoc """
  Elixir interface for Tree-Sitter parsing via Rust NIF.

  Provides fast, incremental parsing of source code with support for
  multiple languages. This is the foundation of Mimo's Living Codebase
  feature (SPEC-021).

  ## Supported Languages

  - Elixir (`.ex`, `.exs`)
  - Python (`.py`, `.pyw`)
  - JavaScript (`.js`, `.mjs`, `.cjs`, `.jsx`)
  - TypeScript (`.ts`, `.tsx`)

  ## Usage

      # Parse a file
      {:ok, tree} = Mimo.Code.TreeSitter.parse_file("/path/to/file.ex")

      # Extract symbols
      {:ok, symbols} = Mimo.Code.TreeSitter.get_symbols(tree)

      # Extract references
      {:ok, refs} = Mimo.Code.TreeSitter.get_references(tree)

      # Run a custom query
      {:ok, matches} = Mimo.Code.TreeSitter.query(tree, "(call target: (identifier) @func)")
  """

  @type tree :: reference()
  @type language :: String.t()
  @type symbol :: %{
          name: String.t(),
          kind: String.t(),
          start_line: non_neg_integer(),
          start_col: non_neg_integer(),
          end_line: non_neg_integer(),
          end_col: non_neg_integer(),
          parent: String.t() | nil
        }
  @type reference_info :: %{
          name: String.t(),
          kind: String.t(),
          line: non_neg_integer(),
          col: non_neg_integer()
        }

  @doc """
  Parse source code and return a tree handle.

  ## Parameters

  - `source` - The source code string to parse
  - `language` - The language name ("elixir", "python", "javascript", "typescript", "tsx")

  ## Returns

  - `{:ok, tree}` - Successfully parsed tree handle
  - `{:error, reason}` - Parse error

  ## Example

      {:ok, tree} = Mimo.Code.TreeSitter.parse("def hello, do: :world", "elixir")
  """
  @spec parse(String.t(), language()) :: {:ok, tree()} | {:error, atom()}
  def parse(source, language) do
    Native.parse(source, language)
  end

  @doc """
  Parse a file, automatically detecting the language from extension.

  ## Parameters

  - `path` - Path to the source file

  ## Returns

  - `{:ok, tree}` - Successfully parsed tree handle
  - `{:error, reason}` - File read or parse error

  ## Example

      {:ok, tree} = Mimo.Code.TreeSitter.parse_file("/path/to/file.ex")
  """
  @spec parse_file(String.t()) :: {:ok, tree()} | {:error, atom() | String.t()}
  def parse_file(path) do
    with {:ok, language} <- language_for_file(path),
         {:ok, source} <- File.read(path) do
      parse(source, language)
    end
  end

  @doc """
  Parse source code incrementally, reusing the old tree.

  This is significantly faster than parsing from scratch when
  only small changes have been made to the source.

  ## Parameters

  - `source` - The new source code string
  - `old_tree` - The previous tree handle
  - `edits` - List of edits as `{start_byte, old_end_byte, new_end_byte}` tuples

  ## Returns

  - `{:ok, tree}` - Successfully parsed tree handle
  - `{:error, reason}` - Parse error
  """
  @spec parse_incremental(String.t(), tree(), [
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
        ]) ::
          {:ok, tree()} | {:error, atom()}
  def parse_incremental(source, old_tree, edits \\ []) do
    Native.parse_incremental(source, old_tree, edits)
  end

  @doc """
  Get the S-expression representation of the AST (for debugging).

  ## Example

      {:ok, tree} = parse("def foo, do: 1", "elixir")
      {:ok, sexp} = get_sexp(tree)
      # => "(source (call target: (identifier) ...))"
  """
  @spec get_sexp(tree()) :: {:ok, String.t()} | {:error, atom()}
  def get_sexp(tree) do
    Native.get_sexp(tree)
  end

  @doc """
  Extract all symbols (functions, classes, modules, etc.) from the parsed tree.

  ## Returns

  A list of symbol maps with:
  - `name` - Symbol name
  - `kind` - Symbol type ("function", "class", "module", etc.)
  - `start_line` - Starting line number (1-indexed)
  - `start_col` - Starting column
  - `end_line` - Ending line number
  - `end_col` - Ending column
  - `parent` - Parent symbol name (for nested symbols)
  - `visibility` - For functions: "public" or "private" (Elixir)

  ## Example

      {:ok, tree} = parse("defmodule Foo do def bar, do: 1 end", "elixir")
      {:ok, symbols} = get_symbols(tree)
      # => [%{name: "Foo", kind: "module", ...}, %{name: "bar", kind: "function", ...}]
  """
  @spec get_symbols(tree()) :: {:ok, [symbol()]} | {:error, atom()}
  def get_symbols(tree) do
    case Native.get_symbols(tree) do
      {:ok, raw_symbols} ->
        symbols = Enum.map(raw_symbols, &parse_symbol_tuple/1)
        {:ok, symbols}

      error ->
        error
    end
  end

  @doc """
  Extract all references (function calls, imports, etc.) from the parsed tree.

  ## Returns

  A list of reference maps with:
  - `name` - Referenced name
  - `kind` - Reference type ("call", "qualified_call", "import", "new")
  - `line` - Line number (1-indexed)
  - `col` - Column number

  ## Example

      {:ok, tree} = parse("IO.puts(:hello)", "elixir")
      {:ok, refs} = get_references(tree)
      # => [%{name: "IO.puts", kind: "qualified_call", ...}]
  """
  @spec get_references(tree()) :: {:ok, [reference_info()]} | {:error, atom()}
  def get_references(tree) do
    case Native.get_references(tree) do
      {:ok, raw_refs} ->
        refs = Enum.map(raw_refs, &parse_reference_tuple/1)
        {:ok, refs}

      error ->
        error
    end
  end

  @doc """
  Execute a Tree-Sitter query pattern on the tree.

  ## Parameters

  - `tree` - The parsed tree handle
  - `pattern` - Tree-Sitter query pattern string

  ## Returns

  A list of match maps with:
  - `capture` - The capture name from the query
  - `text` - The matched text
  - `kind` - The node kind
  - `start_line`, `start_col`, `end_line`, `end_col` - Position info

  ## Example

      # Find all function definitions in Elixir
      {:ok, tree} = parse("def foo, do: 1\\ndef bar, do: 2", "elixir")
      {:ok, matches} = query(tree, "(call target: (identifier) @func (#eq? @func \\"def\\"))")
  """
  @spec query(tree(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def query(tree, pattern) do
    case Native.query(tree, pattern) do
      {:ok, raw_matches} ->
        matches = Enum.map(raw_matches, &parse_query_result/1)
        {:ok, matches}

      error ->
        error
    end
  end

  @doc """
  List all supported languages.

  ## Example

      languages = supported_languages()
      # => ["elixir", "python", "javascript", "typescript", "tsx"]
  """
  @spec supported_languages() :: [String.t()]
  def supported_languages do
    Native.supported_languages()
  end

  @doc """
  Get the language name for a file extension.

  ## Parameters

  - `ext` - File extension without the dot (e.g., "ex", "py")

  ## Returns

  - `{:ok, language}` - The language name
  - `{:error, :unknown_language}` - Unsupported extension
  """
  @spec language_for_extension(String.t()) :: {:ok, String.t()} | {:error, :unknown_language}
  def language_for_extension(ext) do
    Native.language_for_extension(ext)
  end

  @doc """
  Get the language name for a file path.

  ## Parameters

  - `path` - Full file path

  ## Returns

  - `{:ok, language}` - The language name
  - `{:error, :unknown_language}` - Unsupported file type
  """
  @spec language_for_file(String.t()) :: {:ok, String.t()} | {:error, :unknown_language}
  def language_for_file(path) do
    ext = Path.extname(path) |> String.trim_leading(".")
    language_for_extension(ext)
  end

  @doc """
  Check if a file is supported for parsing.
  """
  @spec supported_file?(String.t()) :: boolean()
  def supported_file?(path) do
    case language_for_file(path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Private helpers

  # Known keys from NIF output - whitelist for safe atom conversion
  # SECURITY: Prevents atom table exhaustion if NIF returns unexpected keys
  @symbol_keys ~w(name kind start_line start_col end_line end_col parent visibility)a
               |> MapSet.new(&Atom.to_string/1)
  @reference_keys ~w(name kind line col)a |> MapSet.new(&Atom.to_string/1)
  @query_keys ~w(capture text kind start_line start_col end_line end_col)a
              |> MapSet.new(&Atom.to_string/1)

  defp safe_key_to_atom(key, known_keys) when is_binary(key) do
    if MapSet.member?(known_keys, key) do
      # Safe to use String.to_atom since we've validated against our whitelist
      String.to_atom(key)
    else
      # Keep unknown keys as strings - defensive against NIF changes
      key
    end
  end

  defp parse_symbol_tuple(tuple_list) when is_list(tuple_list) do
    tuple_list
    |> Enum.into(%{}, fn {key, value} ->
      parsed_key = safe_key_to_atom(key, @symbol_keys)

      parsed_value =
        cond do
          parsed_key in [:start_line, :start_col, :end_line, :end_col] ->
            String.to_integer(value)

          parsed_key == :parent and value == "" ->
            nil

          true ->
            value
        end

      {parsed_key, parsed_value}
    end)
  end

  defp parse_reference_tuple(tuple_list) when is_list(tuple_list) do
    tuple_list
    |> Enum.into(%{}, fn {key, value} ->
      parsed_key = safe_key_to_atom(key, @reference_keys)

      parsed_value =
        if parsed_key in [:line, :col] do
          String.to_integer(value)
        else
          value
        end

      {parsed_key, parsed_value}
    end)
  end

  defp parse_query_result(tuple_list) when is_list(tuple_list) do
    tuple_list
    |> Enum.into(%{}, fn {key, value} ->
      parsed_key = safe_key_to_atom(key, @query_keys)

      parsed_value =
        if parsed_key in [:start_line, :start_col, :end_line, :end_col] do
          String.to_integer(value)
        else
          value
        end

      {parsed_key, parsed_value}
    end)
  end
end
