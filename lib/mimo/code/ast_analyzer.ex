defmodule Mimo.Code.AstAnalyzer do
  @moduledoc """
  Analyzes AST from Tree-Sitter to extract symbols and references.

  This module provides the bridge between raw Tree-Sitter parsing
  and the structured symbol/reference data stored in the database.
  Part of SPEC-021 Living Codebase.

  ## Usage

      # Analyze a file
      {:ok, analysis} = Mimo.Code.AstAnalyzer.analyze_file("/path/to/file.ex")

      # Get symbols and references
      %{symbols: symbols, references: refs} = analysis
  """

  alias Mimo.Code.TreeSitter

  require Logger

  @type analysis_result :: %{
          symbols: [map()],
          references: [map()],
          file_path: String.t(),
          language: String.t(),
          file_hash: String.t()
        }

  @doc """
  Analyze a source file and extract symbols and references.

  ## Parameters

  - `file_path` - Path to the source file

  ## Returns

  - `{:ok, analysis}` - Analysis result with symbols and references
  - `{:error, reason}` - Error occurred
  """
  @spec analyze_file(String.t()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_file(file_path) do
    with {:ok, language} <- TreeSitter.language_for_file(file_path),
         {:ok, source} <- File.read(file_path),
         {:ok, tree} <- TreeSitter.parse(source, language) do
      file_hash = compute_hash(source)

      {:ok, raw_symbols} = TreeSitter.get_symbols(tree)
      {:ok, raw_refs} = TreeSitter.get_references(tree)

      symbols = process_symbols(raw_symbols, file_path, language)
      references = process_references(raw_refs, file_path, language)

      {:ok,
       %{
         symbols: symbols,
         references: references,
         file_path: file_path,
         language: language,
         file_hash: file_hash
       }}
    end
  end

  @doc """
  Analyze source code directly (without file).

  ## Parameters

  - `source` - Source code string
  - `language` - Language name
  - `file_path` - Virtual file path for indexing

  ## Returns

  - `{:ok, analysis}` - Analysis result with symbols and references
  - `{:error, reason}` - Error occurred
  """
  @spec analyze_source(String.t(), String.t(), String.t()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze_source(source, language, file_path \\ "virtual") do
    with {:ok, tree} <- TreeSitter.parse(source, language) do
      file_hash = compute_hash(source)

      {:ok, raw_symbols} = TreeSitter.get_symbols(tree)
      {:ok, raw_refs} = TreeSitter.get_references(tree)

      symbols = process_symbols(raw_symbols, file_path, language)
      references = process_references(raw_refs, file_path, language)

      {:ok,
       %{
         symbols: symbols,
         references: references,
         file_path: file_path,
         language: language,
         file_hash: file_hash
       }}
    end
  end

  @doc """
  Check if a file has changed by comparing hashes.
  """
  @spec file_changed?(String.t(), String.t()) :: boolean()
  def file_changed?(file_path, stored_hash) do
    case File.read(file_path) do
      {:ok, source} ->
        compute_hash(source) != stored_hash

      _ ->
        true
    end
  end

  @doc """
  Compute a hash of source content for change detection.
  """
  @spec compute_hash(String.t()) :: String.t()
  def compute_hash(source) do
    :crypto.hash(:md5, source) |> Base.encode16(case: :lower)
  end

  @doc """
  Build qualified names for symbols based on their parent hierarchy.

  This resolves parent references and creates proper qualified names like
  `MyApp.Orders.calculate_total` for nested symbols.
  """
  @spec resolve_qualified_names([map()]) :: [map()]
  def resolve_qualified_names(symbols) do
    # Build a map of symbols by their position for quick lookup
    _symbols_by_pos =
      symbols
      |> Enum.with_index()
      |> Enum.into(%{}, fn {sym, idx} -> {{sym.start_line, sym.start_col}, {sym, idx}} end)

    # First pass: identify parent-child relationships
    symbols
    |> Enum.map(fn symbol ->
      parent_name = find_parent_name(symbol, symbols)

      qualified_name =
        if parent_name && parent_name != "" do
          "#{parent_name}.#{symbol.name}"
        else
          symbol.name
        end

      Map.put(symbol, :qualified_name, qualified_name)
    end)
  end

  # Private helpers

  defp process_symbols(raw_symbols, file_path, language) do
    raw_symbols
    |> Enum.map(fn raw ->
      %{
        name: raw.name,
        kind: normalize_kind(raw.kind),
        visibility: raw[:visibility] || "public",
        start_line: raw.start_line,
        start_col: raw.start_col,
        end_line: raw[:end_line] || raw.start_line,
        end_col: raw[:end_col] || 0,
        parent: raw[:parent],
        file_path: file_path,
        language: language
      }
    end)
    |> resolve_qualified_names()
  end

  defp process_references(raw_refs, file_path, language) do
    raw_refs
    |> Enum.map(fn raw ->
      %{
        name: extract_reference_name(raw.name),
        kind: normalize_ref_kind(raw.kind),
        line: raw.line,
        col: raw.col,
        target_module: extract_module(raw.name),
        file_path: file_path,
        language: language
      }
    end)
    |> Enum.uniq_by(fn ref -> {ref.line, ref.col, ref.name} end)
  end

  defp normalize_kind(kind) do
    case kind do
      "def" -> "function"
      "defp" -> "function"
      "defmacro" -> "macro"
      "defmacrop" -> "macro"
      "defmodule" -> "module"
      "function_definition" -> "function"
      "async_function_definition" -> "function"
      "function_declaration" -> "function"
      "class_definition" -> "class"
      "class_declaration" -> "class"
      "method_definition" -> "method"
      "const" -> "constant"
      "let" -> "variable"
      "var" -> "variable"
      k -> k
    end
  end

  defp normalize_ref_kind(kind) do
    case kind do
      "call" -> "call"
      "qualified_call" -> "qualified_call"
      "dot" -> "qualified_call"
      "new" -> "new"
      k -> k
    end
  end

  defp extract_reference_name(name) do
    # For qualified calls like "Module.function", extract function name
    case String.split(name, ".") do
      parts when length(parts) > 1 -> List.last(parts)
      _ -> name
    end
  end

  defp extract_module(name) do
    case String.split(name, ".") do
      parts when length(parts) > 1 ->
        parts |> Enum.drop(-1) |> Enum.join(".")

      _ ->
        nil
    end
  end

  defp find_parent_name(symbol, all_symbols) do
    parent_ref = symbol[:parent]

    if parent_ref && parent_ref != "" do
      parent_ref
    else
      # Try to find parent by position containment
      find_containing_parent(symbol, all_symbols)
    end
  end

  defp find_containing_parent(symbol, all_symbols) do
    # Find a symbol that contains this one (module/class containing function)
    all_symbols
    |> Enum.filter(fn candidate ->
      candidate.kind in ["module", "class"] &&
        candidate.start_line <= symbol.start_line &&
        candidate.end_line >= symbol.end_line &&
        candidate.name != symbol.name
    end)
    |> Enum.sort_by(fn c -> c.end_line - c.start_line end)
    |> List.first()
    |> case do
      nil -> nil
      parent -> parent.name
    end
  end
end
