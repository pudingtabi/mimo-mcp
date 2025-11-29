defmodule Mix.Tasks.Mimo.Reembed do
  @moduledoc """
  Re-embeds all memories with consistent embeddings.
  
  This fixes the search issue caused by mixed embedding dimensions/methods.
  Run with: mix mimo.reembed
  
  Options:
    --dry-run    Show what would be updated without making changes
    --batch-size Number of records to process at a time (default: 50)
  """
  use Mix.Task
  require Logger

  alias Mimo.Repo
  alias Mimo.Brain.{Engram, LLM}
  import Ecto.Query

  @shortdoc "Re-embed all memories with consistent embeddings"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, 
      strict: [dry_run: :boolean, batch_size: :integer]
    )
    
    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 50)
    
    # Start the application
    Mix.Task.run("app.start")
    
    IO.puts("\n=== Mimo Memory Re-embedding Tool ===")
    IO.puts("Dry run: #{dry_run}")
    IO.puts("Batch size: #{batch_size}")
    
    # Get total count
    total = Repo.aggregate(Engram, :count)
    IO.puts("Total memories to process: #{total}\n")
    
    # Process in batches
    process_batches(0, batch_size, dry_run, 0, 0)
    
    IO.puts("\n=== Re-embedding Complete ===")
  end
  
  defp process_batches(offset, batch_size, dry_run, processed, errors) do
    engrams = Repo.all(
      from e in Engram,
        order_by: e.id,
        offset: ^offset,
        limit: ^batch_size,
        select: %{id: e.id, content: e.content}
    )
    
    if engrams == [] do
      IO.puts("\nProcessed: #{processed}, Errors: #{errors}")
      :ok
    else
      {batch_ok, batch_err} = process_batch(engrams, dry_run)
      
      new_processed = processed + batch_ok
      new_errors = errors + batch_err
      
      IO.write("\rProcessed: #{new_processed} (#{batch_err} errors in batch)")
      
      # Continue with next batch
      process_batches(offset + batch_size, batch_size, dry_run, new_processed, new_errors)
    end
  end
  
  defp process_batch(engrams, dry_run) do
    results = Enum.map(engrams, fn %{id: id, content: content} ->
      case LLM.generate_embedding(content) do
        {:ok, embedding} ->
          if dry_run do
            {:ok, id}
          else
            update_embedding(id, embedding)
          end
        {:error, reason} ->
          Logger.warning("Failed to generate embedding for #{id}: #{inspect(reason)}")
          {:error, id}
      end
    end)
    
    ok_count = Enum.count(results, fn
      {:ok, _} -> true
      _ -> false
    end)
    
    err_count = length(results) - ok_count
    
    {ok_count, err_count}
  end
  
  defp update_embedding(id, embedding) do
    from(e in Engram, where: e.id == ^id)
    |> Repo.update_all(set: [embedding: embedding, updated_at: NaiveDateTime.utc_now()])
    
    {:ok, id}
  rescue
    e ->
      Logger.error("Failed to update embedding for #{id}: #{Exception.message(e)}")
      {:error, id}
  end
end
