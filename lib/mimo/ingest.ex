defmodule Mimo.Ingest do
  @moduledoc """
  File ingestion for Mimo memory with automatic chunking.

  Supports multiple chunking strategies:
  - `:auto` - Detect based on file extension
  - `:paragraphs` - Split on double newlines
  - `:markdown` - Split on markdown headers
  - `:lines` - Split every N lines
  - `:sentences` - Split on sentence boundaries
  - `:whole` - Store entire file as one memory

  ## Usage

      # Auto-detect strategy based on file type
      {:ok, result} = Mimo.Ingest.ingest_file("/path/to/file.md")

      # Specify strategy explicitly
      {:ok, result} = Mimo.Ingest.ingest_file("/path/to/notes.txt", strategy: :paragraphs)

  ## Constraints

  - Max file size: 10MB (configurable)
  - Max chunks per file: 1000 (configurable)
  - Respects SANDBOX_DIR if set
  """

  require Logger
  alias Mimo.Brain.Memory

  # Configuration
  # 10MB
  @max_file_size 10_485_760
  @max_chunks 1000
  # Minimum characters per chunk
  @min_chunk_size 10

  @type strategy :: :auto | :paragraphs | :markdown | :lines | :sentences | :whole
  @type ingest_opts :: [
          strategy: strategy(),
          category: String.t(),
          importance: float(),
          tags: [String.t()],
          chunk_size: pos_integer(),
          overlap: non_neg_integer(),
          metadata: map()
        ]

  @doc """
  Ingest a file into Mimo's memory system.

  ## Options

    * `:strategy` - Chunking strategy (default: `:auto`)
    * `:category` - Memory category (default: `"fact"`)
    * `:importance` - Base importance score (default: `0.5`)
    * `:tags` - Tags to apply to all chunks (default: `[]`)
    * `:chunk_size` - Target chunk size in chars for line-based splitting
    * `:overlap` - Overlap between chunks in chars
    * `:metadata` - Additional metadata map

  ## Returns

      {:ok, %{
        chunks_created: integer,
        file_size: integer,
        strategy_used: atom,
        ids: [binary],
        source_file: string
      }}

      {:error, reason}
  """
  @spec ingest_file(String.t(), ingest_opts()) :: {:ok, map()} | {:error, term()}
  def ingest_file(path, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :auto)
    category = Keyword.get(opts, :category, "fact")
    importance = Keyword.get(opts, :importance, 0.5)
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- check_sandbox(path),
         {:ok, content} <- read_file_safe(path),
         {:ok, actual_strategy} <- resolve_strategy(strategy, path),
         {:ok, chunks} <- chunk_content(content, actual_strategy, opts),
         {:ok, ids} <- store_chunks(chunks, category, importance, tags, path, metadata) do
      :telemetry.execute(
        [:mimo, :ingest, :file],
        %{chunks: length(ids), file_size: byte_size(content)},
        %{path: path, strategy: actual_strategy}
      )

      {:ok,
       %{
         chunks_created: length(ids),
         file_size: byte_size(content),
         strategy_used: actual_strategy,
         ids: ids,
         source_file: path
       }}
    end
  end

  @doc """
  Ingest raw text content with automatic chunking.

  Similar to `ingest_file/2` but accepts text directly.
  """
  @spec ingest_text(String.t(), ingest_opts()) :: {:ok, map()} | {:error, term()}
  def ingest_text(content, opts \\ []) when is_binary(content) do
    strategy = Keyword.get(opts, :strategy, :paragraphs)
    category = Keyword.get(opts, :category, "fact")
    importance = Keyword.get(opts, :importance, 0.5)
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})
    source = Keyword.get(opts, :source, "direct_input")

    with :ok <- validate_content_size(content),
         {:ok, chunks} <- chunk_content(content, strategy, opts),
         {:ok, ids} <- store_chunks(chunks, category, importance, tags, source, metadata) do
      {:ok,
       %{
         chunks_created: length(ids),
         content_size: byte_size(content),
         strategy_used: strategy,
         ids: ids
       }}
    end
  end

  # ============================================================================
  # Sandbox & File Reading
  # ============================================================================

  defp check_sandbox(path) do
    sandbox_dir = System.get_env("SANDBOX_DIR")

    if sandbox_dir do
      expanded_path = Path.expand(path)
      expanded_sandbox = Path.expand(sandbox_dir)

      if String.starts_with?(expanded_path, expanded_sandbox) do
        :ok
      else
        {:error, "Path #{path} is outside sandbox directory #{sandbox_dir}"}
      end
    else
      :ok
    end
  end

  defp read_file_safe(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_size ->
        {:error, {:file_too_large, size, @max_file_size}}

      {:ok, %{type: :regular}} ->
        File.read(path)

      {:ok, %{type: type}} ->
        {:error, {:not_a_file, type}}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp validate_content_size(content) do
    if byte_size(content) > @max_file_size do
      {:error, {:content_too_large, byte_size(content), @max_file_size}}
    else
      :ok
    end
  end

  # ============================================================================
  # Strategy Resolution
  # ============================================================================

  defp resolve_strategy(:auto, path) do
    strategy = detect_strategy(path)
    {:ok, strategy}
  end

  defp resolve_strategy(strategy, _path) when is_atom(strategy) do
    {:ok, strategy}
  end

  defp detect_strategy(path) do
    case Path.extname(path) |> String.downcase() do
      ".md" -> :markdown
      ".markdown" -> :markdown
      ".txt" -> :paragraphs
      ".text" -> :paragraphs
      ".json" -> :whole
      ".yaml" -> :whole
      ".yml" -> :whole
      ".toml" -> :whole
      ".xml" -> :whole
      ".html" -> :whole
      ".htm" -> :whole
      ".ex" -> :paragraphs
      ".exs" -> :paragraphs
      ".py" -> :paragraphs
      ".js" -> :paragraphs
      ".ts" -> :paragraphs
      ".rb" -> :paragraphs
      ".go" -> :paragraphs
      ".rs" -> :paragraphs
      ".java" -> :paragraphs
      ".c" -> :paragraphs
      ".cpp" -> :paragraphs
      ".h" -> :paragraphs
      ".cs" -> :paragraphs
      _ -> :paragraphs
    end
  end

  # ============================================================================
  # Chunking Strategies
  # ============================================================================

  defp chunk_content(content, strategy, opts) do
    chunks = do_chunk(content, strategy, opts)

    # Filter out empty/tiny chunks
    filtered = Enum.filter(chunks, &(String.length(String.trim(&1)) >= @min_chunk_size))

    # Enforce max chunks limit
    if length(filtered) > @max_chunks do
      {:error, {:too_many_chunks, length(filtered), @max_chunks}}
    else
      {:ok, filtered}
    end
  end

  defp do_chunk(content, :paragraphs, _opts) do
    content
    |> String.split(~r/\n\n+/)
    |> Enum.map(&String.trim/1)
  end

  defp do_chunk(content, :markdown, _opts) do
    # Split on markdown headers (# ## ### etc.)
    # Keep the header with its content
    parts = Regex.split(~r/(?=^\#{1,6}\s)/m, content)

    Enum.map(parts, &String.trim/1)
  end

  defp do_chunk(content, :lines, opts) do
    lines_per_chunk = Keyword.get(opts, :chunk_size, 50)

    content
    |> String.split("\n")
    |> Enum.chunk_every(lines_per_chunk)
    |> Enum.map(&Enum.join(&1, "\n"))
    |> Enum.map(&String.trim/1)
  end

  defp do_chunk(content, :sentences, _opts) do
    # Split on sentence boundaries (. ! ?)
    content
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.map(&String.trim/1)
  end

  defp do_chunk(content, :whole, _opts) do
    [String.trim(content)]
  end

  defp do_chunk(content, _unknown, opts) do
    # Fallback to paragraphs
    do_chunk(content, :paragraphs, opts)
  end

  # ============================================================================
  # Storage
  # ============================================================================

  defp store_chunks(chunks, category, importance, tags, source, metadata) do
    total_chunks = length(chunks)

    results =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        chunk_metadata =
          Map.merge(metadata, %{
            "source_file" => source,
            "chunk_index" => index,
            "total_chunks" => total_chunks,
            "tags" => tags
          })

        # Build content with source context
        content_with_context =
          if total_chunks > 1 do
            "[From: #{Path.basename(to_string(source))} (#{index + 1}/#{total_chunks})]\n#{chunk}"
          else
            chunk
          end

        case Memory.persist_memory(content_with_context, category, importance, nil, chunk_metadata) do
          {:ok, engram} ->
            engram_id = if is_map(engram), do: engram.id, else: engram
            {:ok, engram_id}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    # Check if all succeeded
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      ids = Enum.map(results, fn {:ok, id} -> id end)
      {:ok, ids}
    else
      # Rollback: delete any successfully stored chunks to maintain atomicity
      successful_ids =
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, id} -> id end)

      rollback_partial_ingest(successful_ids, source)

      # Report the first error
      {:error, elem(hd(errors), 1)}
    end
  end

  # Rollback partially ingested chunks on failure
  # Ensures atomicity: all chunks stored or none
  defp rollback_partial_ingest([], _source), do: :ok

  defp rollback_partial_ingest(ids, source) do
    Logger.warning("Rolling back #{length(ids)} partially ingested chunks from #{source}")

    deleted_count =
      ids
      |> Enum.map(fn id ->
        case delete_memory(id) do
          :ok ->
            1

          {:error, reason} ->
            Logger.error("Failed to rollback chunk #{id}: #{inspect(reason)}")
            0
        end
      end)
      |> Enum.sum()

    :telemetry.execute(
      [:mimo, :ingest, :rollback],
      %{chunks_rolled_back: deleted_count, chunks_attempted: length(ids)},
      %{source: source}
    )

    if deleted_count == length(ids) do
      Logger.info("Successfully rolled back #{deleted_count} chunks")
      :ok
    else
      Logger.error(
        "Partial rollback: #{deleted_count}/#{length(ids)} chunks deleted. Orphaned data may exist."
      )

      {:error, :partial_rollback}
    end
  end

  # Delete a memory by ID - used for rollback
  defp delete_memory(id) do
    alias Mimo.Repo
    alias Mimo.Brain.Engram

    case Repo.get(Engram, id) do
      nil ->
        # Already deleted or never existed
        :ok

      engram ->
        case Repo.delete(engram) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end
end
