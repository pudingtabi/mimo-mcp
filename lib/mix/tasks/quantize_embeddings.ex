defmodule Mix.Tasks.Mimo.QuantizeEmbeddings do
  @moduledoc """
  Quantizes existing float32 embeddings to int8 format.

  SPEC-031 Phase 2: Storage optimization through int8 quantization.

  ## Usage

      mix mimo.quantize_embeddings [options]

  ## Options

    * `--batch-size` - Number of engrams to process per batch (default: 100)
    * `--dry-run` - Show what would be done without making changes
    * `--force` - Re-quantize even if int8 embedding already exists
    * `--clear-float32` - Clear the original float32 embedding after quantization
    * `--min-dim` - Only quantize embeddings with at least this many dimensions (default: 32)

  ## Examples

      # Quantize all embeddings
      mix mimo.quantize_embeddings

      # Preview without changes
      mix mimo.quantize_embeddings --dry-run

      # Process in larger batches
      mix mimo.quantize_embeddings --batch-size 500

      # Re-quantize all, including already quantized
      mix mimo.quantize_embeddings --force

      # Clear float32 after quantization (maximum storage savings)
      mix mimo.quantize_embeddings --clear-float32

  ## Storage Savings

  Int8 quantization provides ~4x storage reduction:
  - 256-dim float32 JSON: ~5KB
  - 256-dim int8 binary: ~256 bytes + scale/offset

  Combined with MRL truncation (1024→256), total savings: ~16x or more.

  ## Notes

  - Quantization preserves >99% similarity accuracy
  - Original float32 embeddings are kept by default for compatibility
  - Use `--clear-float32` to remove original embeddings for maximum savings
  - Similarity search still works on int8 embeddings with near-identical results
  """

  use Mix.Task
  import Ecto.Query

  alias Mimo.Brain.Engram
  alias Mimo.Repo
  alias Mimo.Vector.Math

  @shortdoc "Quantize float32 embeddings to int8 for storage optimization"

  @switches [
    batch_size: :integer,
    dry_run: :boolean,
    force: :boolean,
    clear_float32: :boolean,
    min_dim: :integer
  ]

  @default_batch_size 100
  @default_min_dim 32

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)
    clear_float32 = Keyword.get(opts, :clear_float32, false)
    min_dim = Keyword.get(opts, :min_dim, @default_min_dim)

    Mix.shell().info("""

    ╔═══════════════════════════════════════════════════════════════╗
    ║  SPEC-031 Phase 2: Int8 Embedding Quantization               ║
    ╚═══════════════════════════════════════════════════════════════╝

    Options:
      Batch size:     #{batch_size}
      Dry run:        #{dry_run}
      Force:          #{force}
      Clear float32:  #{clear_float32}
      Min dimension:  #{min_dim}

    """)

    # Start the application
    Mix.Task.run("app.start", [])

    # Get count of engrams to process
    query = build_query(force, min_dim)
    total_count = Repo.aggregate(query, :count)

    if total_count == 0 do
      Mix.shell().info("✓ No engrams need quantization")
      :ok
    else
      Mix.shell().info("Found #{total_count} engrams to quantize\n")

      if dry_run do
        preview_quantization(query, min_dim)
      else
        quantize_all(query, batch_size, clear_float32, total_count)
      end
    end
  end

  defp build_query(force, min_dim) do
    base_query =
      from(e in Engram,
        where: fragment("json_array_length(?) >= ?", e.embedding, ^min_dim)
      )

    if force do
      base_query
    else
      # Only process engrams that don't have int8 yet
      from(e in base_query, where: is_nil(e.embedding_int8))
    end
  end

  defp preview_quantization(query, min_dim) do
    Mix.shell().info("DRY RUN - Would process the following:\n")

    # Sample first 10 engrams
    samples =
      query
      |> limit(10)
      |> Repo.all()

    for engram <- samples do
      embedding = engram.embedding || []
      dim = length(embedding)

      if dim >= min_dim do
        # Calculate what the quantized size would be
        {:ok, {binary, _scale, _offset}} = Math.quantize_int8(embedding)
        original_size = embedding |> Jason.encode!() |> byte_size()
        # +16 for scale/offset
        quantized_size = byte_size(binary) + 16

        Mix.shell().info("""
          ID: #{engram.id}
          Category: #{engram.category}
          Dimensions: #{dim}
          Original size: #{original_size} bytes
          Quantized size: #{quantized_size} bytes
          Reduction: #{Float.round(original_size / quantized_size, 1)}x
        """)
      end
    end

    # Show total stats
    total_embedding_size =
      query
      |> select([e], fragment("SUM(LENGTH(?))", e.embedding))
      |> Repo.one() || 0

    # Estimate quantized size (1 byte per dimension + 16 for scale/offset per row)
    sample_count = Repo.aggregate(query, :count)
    avg_dim_query = from(e in query, select: avg(fragment("json_array_length(?)", e.embedding)))
    avg_dim = Repo.one(avg_dim_query) || 256
    estimated_int8_size = trunc(sample_count * (avg_dim + 16))

    Mix.shell().info("""

    ═══════════════════════════════════════════════════════════════
    ESTIMATED SAVINGS (dry run)
    ═══════════════════════════════════════════════════════════════
    Total embedding storage (JSON): #{format_bytes(total_embedding_size)}
    Estimated int8 storage:         #{format_bytes(estimated_int8_size)}
    Estimated reduction:            #{Float.round(total_embedding_size / max(estimated_int8_size, 1), 1)}x

    Run without --dry-run to apply quantization.
    """)
  end

  defp quantize_all(query, batch_size, clear_float32, total_count) do
    Mix.shell().info("Starting quantization...\n")

    start_time = System.monotonic_time(:millisecond)

    # Stream must be inside a transaction for Ecto
    {processed, errors, bytes_saved} =
      Repo.transaction(fn ->
        query
        |> Repo.stream()
        |> Stream.with_index(1)
        |> Stream.chunk_every(batch_size)
        |> Enum.reduce({0, 0, 0}, fn batch, {proc_count, err_count, bytes} ->
          {batch_processed, batch_errors, batch_bytes} =
            process_batch(batch, clear_float32, total_count)

          # Progress update
          total_processed = proc_count + batch_processed
          progress = Float.round(total_processed / total_count * 100, 1)
          Mix.shell().info("Progress: #{total_processed}/#{total_count} (#{progress}%)")

          {total_processed, err_count + batch_errors, bytes + batch_bytes}
        end)
      end)
      |> case do
        {:ok, result} ->
          result

        {:error, reason} ->
          Mix.shell().error("Transaction failed: #{inspect(reason)}")
          {0, total_count, 0}
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    Mix.shell().info("""

    ═══════════════════════════════════════════════════════════════
    QUANTIZATION COMPLETE
    ═══════════════════════════════════════════════════════════════
    Processed:     #{processed} engrams
    Errors:        #{errors}
    Storage saved: #{format_bytes(bytes_saved)}
    Time elapsed:  #{elapsed}ms
    Throughput:    #{Float.round(processed / (elapsed / 1000), 1)} engrams/sec
    """)

    if clear_float32 do
      Mix.shell().info("""
      Note: Float32 embeddings were cleared. Only int8 embeddings remain.
      """)
    end
  end

  defp process_batch(batch, clear_float32, _total) do
    Enum.reduce(batch, {0, 0, 0}, fn {engram, _index}, {processed, errors, bytes} ->
      case quantize_engram(engram, clear_float32) do
        {:ok, saved_bytes} ->
          {processed + 1, errors, bytes + saved_bytes}

        {:error, reason} ->
          Mix.shell().error("  Error on engram #{engram.id}: #{inspect(reason)}")
          {processed, errors + 1, bytes}
      end
    end)
  end

  defp quantize_engram(engram, clear_float32) do
    embedding = engram.embedding || []

    if embedding == [] do
      {:error, :empty_embedding}
    else
      case Math.quantize_int8(embedding) do
        {:ok, {binary, scale, offset}} ->
          # Calculate bytes saved
          original_size = embedding |> Jason.encode!() |> byte_size()
          new_size = byte_size(binary) + 16
          bytes_saved = original_size - new_size

          # Build update attrs
          attrs = %{
            embedding_int8: binary,
            embedding_scale: scale,
            embedding_offset: offset
          }

          # Optionally clear float32
          attrs =
            if clear_float32 do
              Map.put(attrs, :embedding, [])
            else
              attrs
            end

          # Update the engram
          case engram
               |> Engram.changeset(attrs)
               |> Repo.update() do
            {:ok, _} ->
              {:ok, max(bytes_saved, 0)}

            {:error, changeset} ->
              {:error, changeset.errors}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
