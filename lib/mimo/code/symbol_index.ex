defmodule Mimo.Code.SymbolIndex do
  @moduledoc """
  Symbol index for code navigation and search.

  Provides CRUD operations and queries for the code symbol database.
  This is the main interface for the Living Codebase feature (SPEC-021).

  ## Usage

      # Index a file
      {:ok, stats} = Mimo.Code.SymbolIndex.index_file("/path/to/file.ex")

      # Find symbols by name
      symbols = Mimo.Code.SymbolIndex.find_by_name("calculate_total")

      # Find all references to a symbol
      refs = Mimo.Code.SymbolIndex.find_references("MyApp.Orders.calculate_total")

      # Search symbols with pattern
      results = Mimo.Code.SymbolIndex.search("auth", kind: "function")
  """

  import Ecto.Query
  alias Mimo.Code.{AstAnalyzer, Symbol, SymbolReference}
  alias Mimo.Repo
  alias Mimo.TaskHelper
  alias Mimo.Code.TreeSitter

  require Logger

  @type index_stats :: %{
          symbols_added: non_neg_integer(),
          symbols_updated: non_neg_integer(),
          references_added: non_neg_integer(),
          file_path: String.t()
        }

  @doc """
  Index a single file, extracting and storing symbols and references.

  This will:
  1. Parse the file using Tree-Sitter
  2. Extract symbols and references
  3. Delete old entries for this file
  4. Insert new entries

  ## Parameters

  - `file_path` - Absolute path to the file

  ## Returns

  - `{:ok, stats}` - Indexing statistics
  - `{:error, reason}` - Indexing failed
  """
  @spec index_file(String.t()) :: {:ok, index_stats()} | {:error, term()}
  def index_file(file_path) do
    Logger.debug("Indexing file: #{file_path}")

    with {:ok, analysis} <- AstAnalyzer.analyze_file(file_path) do
      # Delete existing entries for this file
      delete_file_entries(file_path)

      # Insert new symbols
      {symbols_count, symbol_ids} = insert_symbols(analysis.symbols, analysis.file_hash)

      # Insert new references
      refs_count = insert_references(analysis.references, analysis.file_hash, symbol_ids)

      Logger.info("Indexed #{file_path}: #{symbols_count} symbols, #{refs_count} references")

      {:ok,
       %{
         symbols_added: symbols_count,
         symbols_updated: 0,
         references_added: refs_count,
         file_path: file_path
       }}
    end
  end

  @doc """
  Index multiple files in parallel.
  """
  @spec index_files([String.t()]) :: {:ok, [index_stats()]} | {:error, term()}
  def index_files(file_paths) do
    results =
      file_paths
      |> TaskHelper.async_stream_with_callers(&index_file/1, max_concurrency: 4, timeout: 30_000)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    {:ok, results}
  end

  @doc """
  Index all supported files in a directory recursively.
  """
  @spec index_directory(String.t(), keyword()) :: {:ok, [index_stats()]} | {:error, term()}
  def index_directory(dir_path, opts \\ []) do
    exclude_patterns = opts[:exclude] || [~r/_build/, ~r/deps/, ~r/node_modules/, ~r/\.git/]

    files =
      Path.wildcard(Path.join(dir_path, "**/*"))
      |> Enum.filter(fn path ->
        File.regular?(path) and TreeSitter.supported_file?(path)
      end)
      |> Enum.reject(fn path ->
        Enum.any?(exclude_patterns, &Regex.match?(&1, path))
      end)

    Logger.info("Indexing #{length(files)} files in #{dir_path}")
    index_files(files)
  end

  @doc """
  Remove all index entries for a file.
  """
  @spec remove_file(String.t()) :: {:ok, non_neg_integer()}
  def remove_file(file_path) do
    count = delete_file_entries(file_path)
    {:ok, count}
  end

  @doc """
  Find symbols by name (exact match).
  """
  @spec find_by_name(String.t(), keyword()) :: [Symbol.t()]
  def find_by_name(name, opts \\ []) do
    query =
      from(s in Symbol,
        where: s.name == ^name,
        order_by: [asc: s.file_path, asc: s.start_line]
      )

    query
    |> maybe_filter_kind(opts[:kind])
    |> maybe_filter_language(opts[:language])
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  @doc """
  Find symbols by qualified name (exact match).
  """
  @spec find_by_qualified_name(String.t()) :: [Symbol.t()]
  def find_by_qualified_name(qualified_name) do
    Repo.all(
      from(s in Symbol,
        where: s.qualified_name == ^qualified_name,
        order_by: [asc: s.file_path, asc: s.start_line]
      )
    )
  end

  @doc """
  Find the definition of a symbol.

  Returns the symbol where it's defined (not where it's used).
  """
  @spec find_definition(String.t()) :: Symbol.t() | nil
  def find_definition(name) do
    Repo.one(
      from(s in Symbol,
        where: s.name == ^name or s.qualified_name == ^name,
        where: s.kind in ["function", "class", "module", "method", "macro"],
        order_by: [asc: s.file_path],
        limit: 1
      )
    )
  end

  @doc """
  Find all references to a symbol.
  """
  @spec find_references(String.t(), keyword()) :: [SymbolReference.t()]
  def find_references(name, opts \\ []) do
    query =
      from(r in SymbolReference,
        where: r.name == ^name or r.qualified_name == ^name,
        order_by: [asc: r.file_path, asc: r.line]
      )

    query
    |> maybe_filter_ref_kind(opts[:kind])
    |> maybe_filter_language(opts[:language])
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  @doc """
  Search symbols by pattern (case-insensitive).
  """
  @spec search(String.t(), keyword()) :: [Symbol.t()]
  def search(pattern, opts \\ []) do
    like_pattern = "%#{pattern}%"

    query =
      from(s in Symbol,
        where:
          fragment("? LIKE ? COLLATE NOCASE", s.name, ^like_pattern) or
            fragment("? LIKE ? COLLATE NOCASE", s.qualified_name, ^like_pattern),
        order_by: [
          # Prioritize exact matches
          fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", s.name, ^pattern),
          # Then prefix matches
          fragment("CASE WHEN ? LIKE ? THEN 0 ELSE 1 END", s.name, ^"#{pattern}%"),
          asc: s.name
        ]
      )

    query
    |> maybe_filter_kind(opts[:kind])
    |> maybe_filter_language(opts[:language])
    |> maybe_limit(opts[:limit] || 50)
    |> Repo.all()
  end

  @doc """
  Get all symbols in a file.
  """
  @spec symbols_in_file(String.t()) :: [Symbol.t()]
  def symbols_in_file(file_path) do
    Repo.all(
      from(s in Symbol,
        where: s.file_path == ^file_path,
        order_by: [asc: s.start_line, asc: s.start_col]
      )
    )
  end

  @doc """
  Get all references in a file.
  """
  @spec references_in_file(String.t()) :: [SymbolReference.t()]
  def references_in_file(file_path) do
    Repo.all(
      from(r in SymbolReference,
        where: r.file_path == ^file_path,
        order_by: [asc: r.line, asc: r.col]
      )
    )
  end

  @doc """
  Get symbol at a specific location.
  """
  @spec symbol_at(String.t(), non_neg_integer(), non_neg_integer()) :: Symbol.t() | nil
  def symbol_at(file_path, line, col) do
    Repo.one(
      from(s in Symbol,
        where: s.file_path == ^file_path,
        where: s.start_line <= ^line and s.end_line >= ^line,
        where:
          (s.start_line < ^line or (s.start_line == ^line and s.start_col <= ^col)) and
            (s.end_line > ^line or (s.end_line == ^line and s.end_col >= ^col)),
        order_by: [desc: s.start_line],
        limit: 1
      )
    )
  end

  @doc """
  Get call graph for a symbol (what it calls and what calls it).
  """
  @spec call_graph(String.t()) :: %{callers: [map()], callees: [map()]}
  def call_graph(symbol_name) do
    # Find who calls this symbol
    callers =
      Repo.all(
        from(r in SymbolReference,
          where: r.name == ^symbol_name or r.qualified_name == ^symbol_name,
          where: r.kind in ["call", "qualified_call"],
          select: %{
            file_path: r.file_path,
            line: r.line,
            col: r.col,
            container_id: r.container_id
          }
        )
      )
      |> Enum.map(fn caller ->
        container =
          if caller.container_id do
            Repo.get(Symbol, caller.container_id)
          end

        %{
          file_path: caller.file_path,
          line: caller.line,
          col: caller.col,
          caller_name: container && container.qualified_name
        }
      end)

    # Find what this symbol calls (need to find the symbol first)
    callees =
      case find_definition(symbol_name) do
        nil ->
          []

        symbol ->
          Repo.all(
            from(r in SymbolReference,
              where: r.container_id == ^symbol.id,
              where: r.kind in ["call", "qualified_call"],
              select: %{
                name: r.name,
                qualified_name: r.qualified_name,
                line: r.line
              }
            )
          )
      end

    %{callers: callers, callees: callees}
  end

  @doc """
  Get statistics about the index.
  """
  @spec stats() :: map()
  def stats do
    symbols_count = Repo.aggregate(Symbol, :count)
    refs_count = Repo.aggregate(SymbolReference, :count)

    # SQLite doesn't support count(field, :distinct), use subquery instead
    files_count =
      Repo.one(
        from(s in subquery(from(s in Symbol, distinct: true, select: s.file_path)),
          select: count()
        )
      ) || 0

    kinds =
      Repo.all(
        from(s in Symbol,
          group_by: s.kind,
          select: {s.kind, count(s.id)}
        )
      )
      |> Enum.into(%{})

    %{
      total_symbols: symbols_count,
      total_references: refs_count,
      indexed_files: files_count,
      symbols_by_kind: kinds
    }
  end

  # Private helpers

  defp delete_file_entries(file_path) do
    {symbols_deleted, _} =
      Repo.delete_all(from(s in Symbol, where: s.file_path == ^file_path))

    {refs_deleted, _} =
      Repo.delete_all(from(r in SymbolReference, where: r.file_path == ^file_path))

    symbols_deleted + refs_deleted
  end

  defp insert_symbols(symbols, file_hash) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # First pass: insert all symbols without parent relationships
    symbol_entries =
      symbols
      |> Enum.map(fn sym ->
        %{
          id: Ecto.UUID.generate(),
          file_path: sym.file_path,
          name: sym.name,
          qualified_name: sym.qualified_name || sym.name,
          kind: sym.kind,
          language: sym.language,
          visibility: sym[:visibility] || "public",
          start_line: sym.start_line,
          start_col: sym.start_col,
          end_line: sym.end_line,
          end_col: sym.end_col,
          file_hash: file_hash,
          indexed_at: now,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    # Insert in batches
    {count, _} =
      Repo.insert_all(Symbol, symbol_entries,
        on_conflict: :replace_all,
        conflict_target: [:file_path, :start_line, :start_col, :name]
      )

    # Build a map of symbol names to IDs for reference linking
    symbol_ids =
      symbol_entries
      |> Enum.into(%{}, fn entry -> {entry.qualified_name, entry.id} end)

    {count, symbol_ids}
  end

  defp insert_references(references, file_hash, _symbol_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ref_entries =
      references
      |> Enum.map(fn ref ->
        %{
          id: Ecto.UUID.generate(),
          file_path: ref.file_path,
          name: ref.name,
          qualified_name: ref[:qualified_name] || ref.name,
          kind: ref.kind,
          language: ref.language,
          line: ref.line,
          col: ref.col,
          target_module: ref[:target_module],
          file_hash: file_hash,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(SymbolReference, ref_entries,
        on_conflict: :replace_all,
        conflict_target: [:file_path, :line, :col, :name]
      )

    count
  end

  defp maybe_filter_kind(query, nil), do: query

  defp maybe_filter_kind(query, kind) do
    from(s in query, where: s.kind == ^kind)
  end

  defp maybe_filter_ref_kind(query, nil), do: query

  defp maybe_filter_ref_kind(query, kind) do
    from(r in query, where: r.kind == ^kind)
  end

  defp maybe_filter_language(query, nil), do: query

  defp maybe_filter_language(query, language) do
    from(s in query, where: s.language == ^language)
  end

  defp maybe_limit(query, nil), do: query

  defp maybe_limit(query, limit) do
    from(s in query, limit: ^limit)
  end
end
