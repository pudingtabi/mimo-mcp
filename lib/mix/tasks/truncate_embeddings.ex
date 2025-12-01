defmodule Mix.Tasks.Mimo.TruncateEmbeddings do
  @moduledoc """
  Truncates existing embeddings using MRL (Matryoshka Representation Learning).

  This task truncates embeddings from their current dimension to a smaller
  dimension WITHOUT re-embedding. This is possible because qwen3-embedding
  supports MRL - the first N dimensions preserve semantic meaning.

  ## Usage

      mix mimo.truncate_embeddings              # Truncate to 256 dims (default)
      mix mimo.truncate_embeddings --dim 128    # Truncate to 128 dims

  ## Options

      --dry-run   Show what would be updated without making changes
      --dim       Target dimension (default: 256, min: 32, max: 1024)

  ## Important

  This is a ONE-WAY operation. Once truncated, the original dimensions
  cannot be recovered without re-embedding from scratch.

  Back up your database before running this!

  ## Performance

  This is a fast in-database operation - no Ollama calls required.
  """
  use Mix.Task
  require Logger

  alias Mimo.Repo
  alias Mimo.Brain.Engram
  import Ecto.Query

  @shortdoc "Truncate embeddings using MRL (no re-embedding needed)"
  @default_dim 256
  @max_dim 1024
  @min_dim 32

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, dim: :integer]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    target_dim = Keyword.get(opts, :dim, @default_dim)

    # Validate dimension
    cond do
      target_dim < @min_dim ->
        Mix.raise("Invalid dimension #{target_dim}. Minimum is #{@min_dim}.")

      target_dim > @max_dim ->
        Mix.raise("Invalid dimension #{target_dim}. Maximum is #{@max_dim}.")

      true ->
        :ok
    end

    # Start the application
    Mix.Task.run("app.start")

    IO.puts("\n=== Mimo MRL Embedding Truncation ===")
    IO.puts("Target dimension: #{target_dim}")
    IO.puts("Dry run: #{dry_run}")

    # Count embeddings that need truncation
    count_query =
      from(e in Engram,
        where: fragment("json_array_length(?) > ?", e.embedding, ^target_dim),
        select: count()
      )

    to_truncate = Repo.one(count_query)
    total = Repo.aggregate(Engram, :count)

    IO.puts("Total memories: #{total}")
    IO.puts("Memories to truncate: #{to_truncate}")

    if to_truncate == 0 do
      IO.puts("\n✓ All embeddings already at #{target_dim} dimensions or smaller.")
      System.halt(0)
    end

    # Show sample
    sample =
      Repo.one(
        from(e in Engram,
          where: fragment("json_array_length(?) > ?", e.embedding, ^target_dim),
          select: %{id: e.id, current_dim: fragment("json_array_length(?)", e.embedding)},
          limit: 1
        )
      )

    if sample do
      IO.puts("\nSample: Memory ##{sample.id} has #{sample.current_dim} dimensions → #{target_dim}")
    end

    # Calculate storage savings
    avg_current_dim =
      Repo.one(
        from(e in Engram,
          where: fragment("json_array_length(?) > ?", e.embedding, ^target_dim),
          select: avg(fragment("json_array_length(?)", e.embedding))
        )
      ) || @max_dim

    reduction = Float.round((1 - target_dim / avg_current_dim) * 100, 1)
    IO.puts("Estimated storage reduction: #{reduction}%")

    if dry_run do
      IO.puts("\n[DRY RUN] No changes made.")
    else
      IO.puts("\n⚠️  This will permanently truncate #{to_truncate} embeddings.")
      IO.puts("   Original dimensions CANNOT be recovered without re-embedding.")

      case IO.gets("Continue? [y/N] ") do
        input when input in ["y\n", "Y\n"] ->
          perform_truncation(target_dim, to_truncate)

        _ ->
          IO.puts("Aborted.")
      end
    end
  end

  defp perform_truncation(target_dim, expected_count) do
    IO.puts("\nTruncating embeddings...")
    start_time = System.monotonic_time(:millisecond)

    # Perform the truncation using raw SQL for efficiency
    {_updated, _} =
      Repo.query!(
        """
        UPDATE engrams
        SET 
          embedding = (
            SELECT json_group_array(value)
            FROM (
              SELECT value 
              FROM json_each(embedding) 
              LIMIT $1
            )
          ),
          embedding_dim = $1,
          updated_at = datetime('now')
        WHERE json_array_length(embedding) > $1
        """,
        [target_dim]
      )

    elapsed = System.monotonic_time(:millisecond) - start_time

    # The result from SQLite doesn't give us affected rows in the same way
    # Let's verify by counting again
    remaining =
      Repo.one(
        from(e in Engram,
          where: fragment("json_array_length(?) > ?", e.embedding, ^target_dim),
          select: count()
        )
      )

    truncated = expected_count - remaining

    IO.puts("\n=== Truncation Complete ===")
    IO.puts("Truncated: #{truncated} memories")
    IO.puts("Time: #{elapsed}ms")
    IO.puts("New dimension: #{target_dim}")

    if remaining > 0 do
      IO.puts("⚠️  #{remaining} memories still have larger embeddings (unexpected)")
    else
      IO.puts("✓ All embeddings now at #{target_dim} dimensions or smaller")
    end
  end
end
