defmodule Mix.Tasks.Mimo.RepairEmbeddings do
  @moduledoc """
  Repairs memories that are missing embeddings.

  This task finds engrams that have no embeddings (neither float32 nor int8)
  and generates new embeddings for them. This can happen when:
  - Memories were created before embedding generation was enabled
  - Embedding generation failed during storage
  - Quantization was run on memories that had no float32 embeddings

  ## Usage

      mix mimo.repair_embeddings [options]

  ## Options

    * `--batch-size` - Number of engrams to process per batch (default: 50)
    * `--dry-run` - Show what would be done without making changes
    * `--force` - Skip confirmation prompt
    * `--dim` - Embedding dimension (default: 256, uses MRL truncation)
    * `--quantize` - Also quantize to int8 after generating embeddings (default: true)

  ## Examples

      # Preview orphaned memories
      mix mimo.repair_embeddings --dry-run

      # Repair all orphaned memories
      mix mimo.repair_embeddings --force

      # Repair without int8 quantization
      mix mimo.repair_embeddings --force --no-quantize
  """

  use Mix.Task
  require Logger

  alias Mimo.Repo
  alias Mimo.Brain.{Engram, LLM}
  alias Mimo.Vector.Math
  import Ecto.Query

  @shortdoc "Repair memories missing embeddings"
  @default_dim 256
  @default_batch_size 50

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          batch_size: :integer,
          dim: :integer,
          force: :boolean,
          quantize: :boolean
        ]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    dim = Keyword.get(opts, :dim, @default_dim)
    force = Keyword.get(opts, :force, false)
    quantize = Keyword.get(opts, :quantize, true)

    # Start the application
    Mix.Task.run("app.start", [])

    Mix.shell().info("""

    ╔═══════════════════════════════════════════════════════════════╗
    ║  Mimo Embedding Repair Tool                                   ║
    ╚═══════════════════════════════════════════════════════════════╝

    Options:
      Batch size:     #{batch_size}
      Dry run:        #{dry_run}
      Dimension:      #{dim}
      Auto-quantize:  #{quantize}

    """)

    # Find orphaned memories (no float32 AND no int8)
    orphaned_query =
      from(e in Engram,
        where:
          (is_nil(e.embedding) or e.embedding == ^[]) and
            is_nil(e.embedding_int8),
        order_by: e.id
      )

    total = Repo.aggregate(orphaned_query, :count)

    if total == 0 do
      Mix.shell().info("✓ No orphaned memories found. All memories have embeddings.")
      :ok
    else
      Mix.shell().info("Found #{total} memories missing embeddings\n")

      if dry_run do
        preview_orphaned(orphaned_query)
      else
        if not force do
          Mix.shell().info("⚠️  This will generate embeddings for #{total} memories.")
          Mix.shell().info("   Make sure Ollama is running with qwen3-embedding model.")

          case IO.gets("Continue? [y/N] ") do
            input when input in ["y\n", "Y\n"] ->
              :ok

            _ ->
              Mix.shell().info("Aborted.")
              System.halt(0)
          end
        end

        repair_all(orphaned_query, batch_size, dim, quantize, total)
      end
    end
  end

  defp preview_orphaned(query) do
    Mix.shell().info("DRY RUN - Would repair the following:\n")

    samples =
      query
      |> limit(20)
      |> Repo.all()

    for engram <- samples do
      Mix.shell().info("""
        ID: #{engram.id}
        Category: #{engram.category}
        Content: #{String.slice(engram.content || "", 0, 80)}...
        ---
      """)
    end

    total = Repo.aggregate(query, :count)

    Mix.shell().info("""

    ═══════════════════════════════════════════════════════════════
    SUMMARY (dry run)
    ═══════════════════════════════════════════════════════════════
    Total orphaned memories: #{total}

    Run without --dry-run to repair these memories.
    """)
  end

  defp repair_all(query, batch_size, dim, quantize, total) do
    Mix.shell().info("Starting embedding repair...\n")
    start_time = System.monotonic_time(:millisecond)

    {processed, errors} = process_batches(query, batch_size, dim, quantize, 0, 0, total)

    elapsed = System.monotonic_time(:millisecond) - start_time

    Mix.shell().info("""

    ═══════════════════════════════════════════════════════════════
    REPAIR COMPLETE
    ═══════════════════════════════════════════════════════════════
    Processed:     #{processed} memories
    Errors:        #{errors}
    Time elapsed:  #{elapsed}ms
    Throughput:    #{Float.round(processed / max(elapsed / 1000, 0.001), 1)} memories/sec
    """)

    if quantize do
      Mix.shell().info("Note: Embeddings were generated and quantized to int8.")
    end
  end

  defp process_batches(query, batch_size, dim, quantize, processed, errors, total) do
    # Re-query to get current orphaned memories (in case some were fixed)
    engrams =
      query
      |> limit(^batch_size)
      |> Repo.all()

    if engrams == [] do
      {processed, errors}
    else
      {batch_ok, batch_err} = process_batch(engrams, dim, quantize)

      new_processed = processed + batch_ok
      new_errors = errors + batch_err

      progress = Float.round(new_processed / total * 100, 1)
      Mix.shell().info("Progress: #{new_processed}/#{total} (#{progress}%)")

      # Continue with next batch
      process_batches(query, batch_size, dim, quantize, new_processed, new_errors, total)
    end
  end

  defp process_batch(engrams, dim, quantize) do
    results =
      Enum.map(engrams, fn engram ->
        case LLM.generate_embedding(engram.content, dim: dim) do
          {:ok, embedding} ->
            update_engram(engram, embedding, quantize)

          {:error, reason} ->
            Logger.warning("Failed to generate embedding for #{engram.id}: #{inspect(reason)}")
            {:error, engram.id}
        end
      end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = Enum.count(results, &match?({:error, _}, &1))

    {ok_count, err_count}
  end

  defp update_engram(engram, embedding, quantize) do
    attrs =
      if quantize do
        # Generate int8 quantization
        case Math.quantize_int8(embedding) do
          {:ok, {binary, scale, offset}} ->
            %{
              # Clear float32 for storage savings
              embedding: [],
              embedding_int8: binary,
              embedding_scale: scale,
              embedding_offset: offset
            }

          {:error, _reason} ->
            # Fallback to just storing float32
            %{embedding: embedding}
        end
      else
        %{embedding: embedding}
      end

    case engram
         |> Engram.changeset(attrs)
         |> Repo.update() do
      {:ok, _} ->
        {:ok, engram.id}

      {:error, changeset} ->
        Logger.warning("Failed to update engram #{engram.id}: #{inspect(changeset.errors)}")
        {:error, engram.id}
    end
  end
end
