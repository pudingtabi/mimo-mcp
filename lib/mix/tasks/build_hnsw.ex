defmodule Mix.Tasks.Mimo.BuildHnsw do
  @moduledoc """
  Builds or rebuilds the HNSW index from existing engram embeddings.

  This task should be run:
  - After initial setup with existing data
  - After bulk imports
  - Periodically if the index becomes stale

  ## Usage

      # Build index (creates new or rebuilds existing)
      mix mimo.build_hnsw

      # Force rebuild even if index exists
      mix mimo.build_hnsw --force

      # Specify custom index path
      mix mimo.build_hnsw --path priv/custom_index.usearch

      # Dry run - just report what would be indexed
      mix mimo.build_hnsw --dry-run

  ## Options

    - `--force` - Rebuild index even if one exists
    - `--path` - Custom path for the index file
    - `--dry-run` - Only show statistics, don't build

  ## SPEC-033 Phase 3b

  This task is part of the HNSW index implementation for O(log n) approximate
  nearest neighbor search. The index uses int8 quantized vectors stored in
  engrams.embedding_int8.
  """

  use Mix.Task

  alias Mimo.Brain.Engram
  alias Mimo.Repo
  alias Mimo.Vector.Math

  import Ecto.Query

  @shortdoc "Builds HNSW index for vector search"

  @default_index_path "priv/hnsw_index.usearch"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          path: :string,
          dry_run: :boolean
        ],
        aliases: [
          f: :force,
          p: :path,
          n: :dry_run
        ]
      )

    force = Keyword.get(opts, :force, false)
    index_path = Keyword.get(opts, :path, @default_index_path)
    dry_run = Keyword.get(opts, :dry_run, false)

    # Start the application (need Repo and NIF)
    Mix.Task.run("app.start")

    # Check current state
    index_exists = File.exists?(index_path)

    # Count engrams with int8 embeddings
    total_count =
      from(e in Engram, where: not is_nil(e.embedding_int8), select: count())
      |> Repo.one()

    # Sample to get dimensions
    sample =
      from(e in Engram, where: not is_nil(e.embedding_int8), limit: 1, select: e.embedding_int8)
      |> Repo.one()

    dimensions = if sample, do: byte_size(sample), else: 256

    Mix.shell().info("""

    HNSW Index Builder
    ==================

    Index path:     #{index_path}
    Index exists:   #{index_exists}
    Force rebuild:  #{force}
    Dry run:        #{dry_run}

    Database Statistics:
    - Engrams with int8 embeddings: #{total_count}
    - Vector dimensions: #{dimensions}

    """)

    cond do
      dry_run ->
        Mix.shell().info("Dry run complete. Use without --dry-run to build index.")

      total_count == 0 ->
        Mix.shell().error(
          "No engrams with int8 embeddings found. Run `mix mimo.vectorize_int8` first."
        )

      index_exists and not force ->
        Mix.shell().info("""
        Index already exists. Use --force to rebuild.

        Current index stats:
        """)

        case Math.hnsw_load(index_path) do
          {:ok, index} ->
            {:ok, size} = Math.hnsw_size(index)
            {:ok, capacity} = Math.hnsw_capacity(index)

            Mix.shell().info("""
            - Size: #{size} vectors
            - Capacity: #{capacity}
            - Up to date: #{size == total_count}
            """)

            if size != total_count do
              Mix.shell().info("""
              Note: Index has #{size} vectors but database has #{total_count} engrams.
              Consider running with --force to rebuild.
              """)
            end

          {:error, reason} ->
            Mix.shell().error("Failed to load existing index: #{inspect(reason)}")
            Mix.shell().info("Run with --force to rebuild.")
        end

      true ->
        build_index(index_path, dimensions, total_count)
    end
  end

  defp build_index(index_path, dimensions, total_count) do
    Mix.shell().info("Building HNSW index with #{total_count} vectors...")

    # Create new index with good defaults for ANN search
    connectivity = 16
    expansion_add = 128
    expansion_search = 64

    case Math.hnsw_new(dimensions, connectivity, expansion_add, expansion_search) do
      {:ok, index} ->
        # Reserve capacity
        Mix.shell().info("Reserving capacity for #{total_count} vectors...")
        Math.hnsw_reserve(index, total_count)

        # Build in batches
        batch_size = 1000
        added = build_in_batches(index, batch_size, total_count)

        Mix.shell().info("\nIndexed #{added} vectors.")

        # Save the index
        Mix.shell().info("Saving index to #{index_path}...")
        dir = Path.dirname(index_path)
        File.mkdir_p!(dir)

        case Math.hnsw_save(index, index_path) do
          {:ok, :ok} ->
            file_size = File.stat!(index_path).size

            Mix.shell().info("""

            ✅ HNSW index built successfully!

            Index saved:    #{index_path}
            Vectors:        #{added}
            File size:      #{format_bytes(file_size)}

            The index will be auto-loaded by Mimo.Brain.HnswIndex on startup.
            """)

          {:error, reason} ->
            Mix.shell().error("Failed to save index: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to create index: #{inspect(reason)}")
    end
  end

  defp build_in_batches(index, batch_size, total) do
    # Stream all engrams with embeddings
    query =
      from(e in Engram,
        where: not is_nil(e.embedding_int8),
        select: {e.id, e.embedding_int8},
        order_by: [asc: e.id]
      )

    # Process in batches with progress
    progress_bar = IO.ANSI.clear_line() <> "\r"

    query
    |> Repo.stream(max_rows: batch_size)
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      case Math.hnsw_add_batch(index, batch) do
        {:ok, count} ->
          new_total = acc + count
          percent = Float.round(new_total * 100 / total, 1)
          IO.write("#{progress_bar}Progress: #{percent}% (#{new_total}/#{total})")
          new_total

        {:error, reason} ->
          Mix.shell().error("\nBatch add failed: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
