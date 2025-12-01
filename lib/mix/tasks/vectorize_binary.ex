defmodule Mix.Tasks.Mimo.VectorizeBinary do
  @moduledoc """
  SPEC-033 Phase 3a: Convert int8 embeddings to binary format for fast pre-filtering.

  Binary embeddings enable ultra-fast Hamming distance computation for
  approximate nearest neighbor pre-filtering before expensive cosine similarity.

  ## Usage

      # Convert all embeddings
      mix mimo.vectorize_binary

      # Convert with batch size
      mix mimo.vectorize_binary --batch-size 500

      # Dry run (count only, no changes)
      mix mimo.vectorize_binary --dry-run

      # Verbose output
      mix mimo.vectorize_binary --verbose
  """
  use Mix.Task

  import Ecto.Query
  require Logger

  alias Mimo.Repo
  alias Mimo.Brain.Engram
  alias Mimo.Vector.Math

  @shortdoc "Convert int8 embeddings to binary format for fast Hamming pre-filtering"

  @switches [
    batch_size: :integer,
    dry_run: :boolean,
    verbose: :boolean
  ]

  @aliases [
    b: :batch_size,
    d: :dry_run,
    v: :verbose
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    batch_size = Keyword.get(opts, :batch_size, 1000)
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)

    # Start the application
    Mix.Task.run("app.start")

    IO.puts("\n#{IO.ANSI.cyan()}=== SPEC-033 Binary Embedding Conversion ===##{IO.ANSI.reset()}")
    IO.puts("Converting int8 embeddings to binary format for fast Hamming pre-filtering\n")

    if dry_run do
      IO.puts("#{IO.ANSI.yellow()}[DRY RUN] No changes will be made#{IO.ANSI.reset()}\n")
    end

    # Count engrams to process
    to_process_count = count_engrams_to_process()
    already_processed = count_engrams_with_binary()
    total_with_int8 = count_engrams_with_int8()

    IO.puts("Statistics:")
    IO.puts("  Total engrams with int8 embedding: #{total_with_int8}")
    IO.puts("  Already have binary embedding:     #{already_processed}")
    IO.puts("  Need processing:                   #{to_process_count}")
    IO.puts("")

    if to_process_count == 0 do
      IO.puts("#{IO.ANSI.green()}✓ All embeddings already converted!#{IO.ANSI.reset()}")
      :ok
    else
      if dry_run do
        IO.puts("Would convert #{to_process_count} embeddings to binary format")
        :ok
      else
        process_embeddings(batch_size, verbose)
      end
    end
  end

  defp count_engrams_to_process do
    Repo.one(
      from(e in Engram,
        where: not is_nil(e.embedding_int8) and is_nil(e.embedding_binary),
        select: count(e.id)
      )
    ) || 0
  end

  defp count_engrams_with_binary do
    Repo.one(
      from(e in Engram,
        where: not is_nil(e.embedding_binary),
        select: count(e.id)
      )
    ) || 0
  end

  defp count_engrams_with_int8 do
    Repo.one(
      from(e in Engram,
        where: not is_nil(e.embedding_int8),
        select: count(e.id)
      )
    ) || 0
  end

  defp process_embeddings(batch_size, verbose) do
    IO.puts("Processing in batches of #{batch_size}...")
    IO.puts("")

    start_time = System.monotonic_time(:millisecond)

    {processed, errors} = process_batches(batch_size, verbose, 0, 0)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    IO.puts("")
    IO.puts("#{IO.ANSI.cyan()}=== Conversion Complete ===##{IO.ANSI.reset()}")
    IO.puts("  Processed: #{processed}")
    IO.puts("  Errors:    #{errors}")
    IO.puts("  Duration:  #{Float.round(duration_ms / 1000, 2)}s")

    # Calculate storage savings
    # 32 bytes per 256-dim binary embedding
    binary_bytes = processed * 32
    IO.puts("  Binary storage used: #{format_bytes(binary_bytes)}")

    if errors > 0 do
      IO.puts(
        "\n#{IO.ANSI.yellow()}⚠ Some embeddings failed to convert. Run with --verbose for details.#{IO.ANSI.reset()}"
      )
    else
      IO.puts("\n#{IO.ANSI.green()}✓ All embeddings converted successfully!#{IO.ANSI.reset()}")
    end

    :ok
  end

  defp process_batches(batch_size, verbose, processed_acc, error_acc) do
    # Get next batch of engrams needing conversion
    engrams =
      from(e in Engram,
        where: not is_nil(e.embedding_int8) and is_nil(e.embedding_binary),
        limit: ^batch_size,
        select: %{id: e.id, embedding_int8: e.embedding_int8}
      )
      |> Repo.all()

    if engrams == [] do
      {processed_acc, error_acc}
    else
      {batch_processed, batch_errors} = process_batch(engrams, verbose)

      # Progress indicator
      total_processed = processed_acc + batch_processed
      IO.write("\r  Converted: #{total_processed} engrams")

      process_batches(batch_size, verbose, total_processed, error_acc + batch_errors)
    end
  end

  defp process_batch(engrams, verbose) do
    results =
      Enum.map(engrams, fn %{id: id, embedding_int8: int8} ->
        case convert_to_binary(int8) do
          {:ok, binary} ->
            case update_engram(id, binary) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                if verbose do
                  IO.puts("\n  Error updating engram #{id}: #{inspect(reason)}")
                end

                :error
            end

          {:error, reason} ->
            if verbose do
              IO.puts("\n  Error converting engram #{id}: #{inspect(reason)}")
            end

            :error
        end
      end)

    processed = Enum.count(results, &(&1 == :ok))
    errors = Enum.count(results, &(&1 == :error))

    {processed, errors}
  end

  defp convert_to_binary(int8) when is_binary(int8) do
    Math.int8_to_binary(int8)
  end

  defp convert_to_binary(_), do: {:error, :invalid_int8}

  defp update_engram(id, binary) do
    from(e in Engram, where: e.id == ^id)
    |> Repo.update_all(set: [embedding_binary: binary])
    |> case do
      {1, _} -> {:ok, id}
      {0, _} -> {:error, :not_found}
      _ -> {:error, :update_failed}
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end
