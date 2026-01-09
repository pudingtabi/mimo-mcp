defmodule Mix.Tasks.Mimo.Reembed do
  @moduledoc """
  Re-embeds all memories with consistent embeddings.

  This task regenerates embeddings for all memories, optionally with a
  specific dimension using MRL (Matryoshka Representation Learning) truncation.

  ## Usage

      mix mimo.reembed              # Re-embed with default dimension (256)
      mix mimo.reembed --dim 512    # Re-embed with 512 dimensions
      mix mimo.reembed --dim 1024   # Re-embed with full 1024 dimensions

  ## Options

      --dry-run      Show what would be updated without making changes
      --batch-size   Number of records to process at a time (default: 50)
      --dim          Embedding dimension (default: 256, max: 1024)
                     Uses MRL truncation - qwen3-embedding supports this natively
      --force        Skip confirmation prompt

  ## MRL (Matryoshka Representation Learning)

  qwen3-embedding produces 1024-dim vectors, but the first N dimensions
  are optimized for reduced dimensionality. This means we can truncate
  to 256 dims with <3% quality loss and 4x storage savings.

  ## Examples

      # Re-embed all memories with MRL truncation to 256 dims (recommended)
      mix mimo.reembed --dim 256

      # Restore full 1024-dim embeddings (after migration rollback)
      mix mimo.reembed --dim 1024

      # Preview what would happen
      mix mimo.reembed --dry-run
  """
  use Mix.Task
  require Logger

  alias Mimo.Brain.{Engram, LLM}
  alias Mimo.Repo
  import Ecto.Query

  @shortdoc "Re-embed all memories with consistent embeddings"
  @default_dim 256
  @max_dim 1024

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, batch_size: :integer, dim: :integer, force: :boolean]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 50)
    dim = Keyword.get(opts, :dim, @default_dim)
    force = Keyword.get(opts, :force, false)

    # Validate dimension
    if dim < 32 or dim > @max_dim do
      Mix.raise("Invalid dimension #{dim}. Must be between 32 and #{@max_dim}.")
    end

    # Start the application
    Mix.Task.run("app.start")

    IO.puts("\n=== Mimo Memory Re-embedding Tool ===")
    IO.puts("Dry run: #{dry_run}")
    IO.puts("Batch size: #{batch_size}")
    IO.puts("Embedding dimension: #{dim}")

    IO.puts(
      "MRL truncation: #{if dim < @max_dim, do: "enabled (#{@max_dim} → #{dim})", else: "disabled"}"
    )

    # Get total count
    total = Repo.aggregate(Engram, :count)
    IO.puts("Total memories to process: #{total}\n")

    # Confirm unless dry_run or force
    if not dry_run and not force and total > 0 do
      IO.puts("⚠️  This will re-embed all #{total} memories.")
      IO.puts("   Make sure Ollama is running with qwen3-embedding model.")

      case IO.gets("Continue? [y/N] ") do
        input when input in ["y\n", "Y\n"] ->
          :ok

        _ ->
          IO.puts("Aborted.")
          System.halt(0)
      end
    end

    # Process in batches
    {processed, errors} = process_batches(0, batch_size, dry_run, dim, 0, 0)

    IO.puts("\n\n=== Re-embedding Complete ===")
    IO.puts("Processed: #{processed}")
    IO.puts("Errors: #{errors}")

    if not dry_run and processed > 0 do
      IO.puts("\nEmbeddings updated to #{dim} dimensions.")
      IO.puts("Storage savings: #{Float.round((1 - dim / @max_dim) * 100, 1)}% reduction")
    end
  end

  defp process_batches(offset, batch_size, dry_run, dim, processed, errors) do
    engrams =
      Repo.all(
        from(e in Engram,
          order_by: e.id,
          offset: ^offset,
          limit: ^batch_size,
          select: %{id: e.id, content: e.content}
        )
      )

    if engrams == [] do
      {processed, errors}
    else
      {batch_ok, batch_err} = process_batch(engrams, dry_run, dim)

      new_processed = processed + batch_ok
      new_errors = errors + batch_err

      IO.write("\rProcessed: #{new_processed} (#{batch_err} errors in batch)   ")

      # Continue with next batch
      process_batches(offset + batch_size, batch_size, dry_run, dim, new_processed, new_errors)
    end
  end

  defp process_batch(engrams, dry_run, dim) do
    results =
      Enum.map(engrams, fn %{id: id, content: content} ->
        # Generate embedding with specified dimension
        case LLM.generate_embedding(content, dim: dim) do
          {:ok, embedding} ->
            if dry_run do
              {:ok, id}
            else
              update_embedding(id, embedding, dim)
            end

          {:error, reason} ->
            Logger.warning("Failed to generate embedding for #{id}: #{inspect(reason)}")
            {:error, id}
        end
      end)

    ok_count =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    err_count = length(results) - ok_count

    {ok_count, err_count}
  end

  defp update_embedding(id, embedding, dim) do
    from(e in Engram, where: e.id == ^id)
    |> Repo.update_all(
      set: [
        embedding: embedding,
        embedding_dim: dim,
        updated_at: NaiveDateTime.utc_now()
      ]
    )

    {:ok, id}
  rescue
    e ->
      Logger.error("Failed to update embedding for #{id}: #{Exception.message(e)}")
      {:error, id}
  end
end
