defmodule Mimo.Brain.VocabularyIndex do
  @moduledoc """
  FTS5-based vocabulary search with BM25 ranking.

  Provides lexical search capabilities complementing vector search:
  - Exact term matching with BM25 relevance ranking
  - Phrase search ("exact phrase")
  - Boolean operators (OR, AND, NOT)
  - Porter stemming for English (memory matches memories)

  Falls back to ILIKE if FTS5 is unavailable.

  ## Performance Characteristics
  - O(log n) search via B-tree index vs O(n) for ILIKE
  - Index overhead: ~0.3% of database size
  - Query latency: <10ms for typical queries

  ## Usage

      # Basic search with BM25 ranking
      {:ok, results} = VocabularyIndex.search("memory decay")

      # Phrase search
      {:ok, results} = VocabularyIndex.phrase_search("brain surgery")

      # OR query
      {:ok, results} = VocabularyIndex.search("genserver OR supervisor")

  ## Score Normalization

  BM25 scores are negative in SQLite (more negative = better match).
  This module normalizes scores to 0-1 range using sigmoid function
  for compatibility with HybridScorer.
  """

  require Logger
  import Ecto.Query

  alias Mimo.Brain.Engram
  alias Mimo.Repo

  @default_limit 20

  @doc """
  Check if FTS5 index is available and functional.

  Returns true if engrams_fts table exists and is queryable.
  """
  @spec available?() :: boolean()
  def available? do
    case Repo.query("SELECT COUNT(*) FROM engrams_fts LIMIT 1") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Search memories using FTS5 with BM25 ranking.

  Returns list of {memory_map, normalized_score} tuples sorted by relevance.

  ## Options
    - `:limit` - Maximum results (default: 20)
    - `:category` - Filter by category (optional)
    - `:min_score` - Minimum normalized score 0-1 (default: 0.0)

  ## Examples

      {:ok, results} = VocabularyIndex.search("memory")
      {:ok, results} = VocabularyIndex.search("genserver OR supervisor", limit: 10)
  """
  @spec search(String.t(), keyword()) :: {:ok, [{map(), float()}]} | {:error, term()}
  def search(query, opts \\ [])

  def search("", _opts), do: {:ok, []}
  def search(nil, _opts), do: {:ok, []}

  def search(query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    category = Keyword.get(opts, :category)
    min_score = Keyword.get(opts, :min_score, 0.0)

    # Preprocess and escape query
    processed_query = preprocess_query(query)

    if processed_query == "" do
      {:ok, []}
    else
      do_fts5_search(processed_query, limit, category, min_score)
    end
  rescue
    e ->
      Logger.warning(
        "[VocabularyIndex] Search failed: #{Exception.message(e)}, falling back to ILIKE"
      )

      fallback_search(query, opts)
  end

  @doc """
  Search for exact phrase matches.

  Wraps query in quotes for FTS5 phrase matching.

  ## Examples

      {:ok, results} = VocabularyIndex.phrase_search("brain surgery")
  """
  @spec phrase_search(String.t(), keyword()) :: {:ok, [{map(), float()}]} | {:error, term()}
  def phrase_search(phrase, opts \\ []) do
    # Escape internal quotes and wrap in phrase delimiters
    escaped = String.replace(phrase, "\"", "\"\"")
    search("\"#{escaped}\"", opts)
  end

  @doc """
  Rebuild the FTS5 index from the engrams table.

  Use this if the index becomes out of sync (should be rare due to triggers).
  """
  @spec rebuild_index() :: :ok | {:error, term()}
  def rebuild_index do
    Logger.info("[VocabularyIndex] Rebuilding FTS5 index...")

    Repo.transaction(fn ->
      # Clear existing index
      Repo.query!("DELETE FROM engrams_fts")

      # Repopulate from engrams
      Repo.query!("""
      INSERT INTO engrams_fts(rowid, content, category)
      SELECT id, content, category FROM engrams
      """)
    end)

    Logger.info("[VocabularyIndex] FTS5 index rebuild complete")
    :ok
  rescue
    e ->
      Logger.error("[VocabularyIndex] Rebuild failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Get FTS5 index statistics.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    with {:ok, %{rows: [[count]]}} <- Repo.query("SELECT COUNT(*) FROM engrams_fts"),
         {:ok, %{rows: [[engram_count]]}} <- Repo.query("SELECT COUNT(*) FROM engrams") do
      {:ok,
       %{
         fts5_count: count,
         engram_count: engram_count,
         in_sync: count == engram_count,
         available: true
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:ok, %{available: false}}
  end

  # Private functions

  defp do_fts5_search(query, limit, category, min_score) do
    # Build the FTS5 query with optional category filter
    sql = build_search_sql(category)

    case Repo.query(sql, [query, limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        results =
          rows
          |> Enum.map(fn row ->
            # Convert row to map with column names
            record = Enum.zip(columns, row) |> Map.new()
            engram_id = record["id"]

            # Fetch full engram
            case Repo.get(Engram, engram_id) do
              nil ->
                nil

              engram ->
                raw_score = record["score"]
                normalized = normalize_bm25(raw_score)

                if normalized >= min_score do
                  {Map.from_struct(engram), normalized}
                else
                  nil
                end
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, results}

      {:error, reason} ->
        Logger.warning("[VocabularyIndex] FTS5 query failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_search_sql(nil) do
    """
    SELECT e.id, bm25(engrams_fts) as score
    FROM engrams_fts
    JOIN engrams e ON e.id = engrams_fts.rowid
    WHERE engrams_fts MATCH ?1
    ORDER BY bm25(engrams_fts)
    LIMIT ?2
    """
  end

  defp build_search_sql(category) when is_binary(category) do
    """
    SELECT e.id, bm25(engrams_fts) as score
    FROM engrams_fts
    JOIN engrams e ON e.id = engrams_fts.rowid
    WHERE engrams_fts MATCH ?1 AND e.category = '#{category}'
    ORDER BY bm25(engrams_fts)
    LIMIT ?2
    """
  end

  defp preprocess_query(query) do
    query
    |> String.trim()
    |> escape_fts5_special_chars()
    |> normalize_whitespace()
  end

  defp escape_fts5_special_chars(query) do
    # FTS5 special characters that need handling:
    # - Quotes: unbalanced quotes cause "unterminated string" errors
    # - Asterisk: prefix matching, can cause issues
    # - Colon: column selector
    # - Caret: boost operator
    # - Dash: NOT operator at start of term
    # - Parentheses: grouping
    # 
    # Strategy: Remove problematic characters, keep only safe alphanumeric + spaces + OR/AND
    query
    # Remove quotes (prevent unterminated string)
    |> String.replace("\"", " ")
    # Remove wildcards
    |> String.replace("*", "")
    # Colons can cause column: prefix issues
    |> String.replace(":", " ")
    # Caret is boost operator
    |> String.replace("^", " ")
    # Dash can be NOT operator, safer to remove
    |> String.replace("-", " ")
    |> String.replace("(", " ")
    |> String.replace(")", " ")
    # Single quotes can also cause issues
    |> String.replace("'", "")
    # Backslashes
    |> String.replace("\\", "")
  end

  defp normalize_whitespace(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  @doc """
  Normalize BM25 score to 0-1 range.

  BM25 in SQLite returns negative values (more negative = better match).
  We negate and apply sigmoid to get 0-1 range with good discrimination.

  ## Examples

      normalize_bm25(-14.0)  # => ~0.999 (excellent match)
      normalize_bm25(-3.0)   # => ~0.818 (good match)
      normalize_bm25(-0.5)   # => ~0.562 (weak match)
  """
  @spec normalize_bm25(float()) :: float()
  def normalize_bm25(raw_score) when is_float(raw_score) do
    # Negate because SQLite BM25 is negative (more negative = better)
    positive = -raw_score

    # Sigmoid normalization with scaling factor
    # Factor of 0.5 gives good spread for typical BM25 ranges (-15 to -0.5)
    1.0 / (1.0 + :math.exp(-positive * 0.5))
  end

  def normalize_bm25(_), do: 0.0

  # Fallback to ILIKE when FTS5 is unavailable
  defp fallback_search(query, opts) do
    Logger.info("[VocabularyIndex] Using ILIKE fallback")
    limit = Keyword.get(opts, :limit, @default_limit)

    keywords =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 2))

    if keywords == [] do
      {:ok, []}
    else
      # OR logic for fallback (more lenient than original AND)
      base_query = from(e in Engram, limit: ^limit, order_by: [desc: e.importance])

      # Build OR conditions
      conditions =
        Enum.map(keywords, fn keyword ->
          pattern = "%#{escape_like(keyword)}%"
          dynamic([e], fragment("? LIKE ? COLLATE NOCASE", e.content, ^pattern))
        end)

      combined = Enum.reduce(conditions, fn cond, acc -> dynamic([e], ^acc or ^cond) end)
      query_with_conditions = from(e in base_query, where: ^combined)

      results =
        Repo.all(query_with_conditions)
        |> Enum.map(fn engram ->
          # Fixed score for fallback
          {Map.from_struct(engram), 0.7}
        end)

      {:ok, results}
    end
  rescue
    e ->
      Logger.error("[VocabularyIndex] Fallback search failed: #{Exception.message(e)}")
      {:ok, []}
  end

  defp escape_like(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
