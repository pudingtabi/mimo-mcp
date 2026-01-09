defmodule Mimo.Brain.KnowledgeSyncer do
  @moduledoc """
  Automatically syncs episodic memories to semantic knowledge graph.

  Implements the CoALA feedback loop where experiences (memories) are
  consolidated into structured knowledge (triples).

  The syncer:
  1. Periodically scans unprocessed memories
  2. Extracts entities and relationships using pattern matching
  3. Creates knowledge triples via SemanticStore.Ingestor
  4. Links memories to relevant code/concepts via Synapse

  This enables Mimo to build knowledge autonomously from experiences.
  """

  use GenServer
  require Logger

  alias Mimo.Brain.Engram
  alias Mimo.Repo
  alias Mimo.SafeCall
  alias Mimo.SemanticStore.Ingestor
  import Ecto.Query

  # Sync every 5 minutes
  @sync_interval :timer.minutes(5)

  # Process at most 20 memories per cycle to avoid overload
  @batch_size 20

  # Minimum importance to consider for knowledge extraction
  @min_importance 0.5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate sync cycle (for testing or manual invocation).
  Returns {:ok, result} or {:error, :unavailable} if syncer is down.
  """
  def sync_now do
    SafeCall.genserver(__MODULE__, :sync_now,
      timeout: 30_000,
      raw: true,
      fallback: {:error, :syncer_unavailable}
    )
  end

  @doc """
  Get sync statistics.
  Returns stats map or empty stats if syncer is down.
  """
  def stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, total_synced: 0, total_triples: 0, errors: 0}
    )
  end

  @doc """
  Process a single memory and extract knowledge from it.
  Returns {:ok, count} with number of triples created.
  """
  def process_memory(memory_id) when is_integer(memory_id) do
    case Repo.get(Engram, memory_id) do
      nil -> {:error, :not_found}
      memory -> do_process_memory(memory)
    end
  end

  def process_memory(%Engram{} = memory) do
    do_process_memory(memory)
  end

  @impl true
  def init(_opts) do
    # Schedule first sync after a short delay
    schedule_sync(5_000)

    state = %{
      last_sync: nil,
      total_synced: 0,
      total_triples: 0,
      errors: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {result, new_state} = run_sync_cycle(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:sync, state) do
    {_result, new_state} = run_sync_cycle(state)
    schedule_sync(@sync_interval)
    {:noreply, new_state}
  end

  defp schedule_sync(delay) do
    Process.send_after(self(), :sync, delay)
  end

  defp run_sync_cycle(state) do
    Logger.debug("[KnowledgeSyncer] Starting sync cycle")

    # Get unprocessed high-importance memories
    memories = get_unprocessed_memories()

    if Enum.empty?(memories) do
      Logger.debug("[KnowledgeSyncer] No memories to process")
      {{:ok, 0}, %{state | last_sync: DateTime.utc_now()}}
    else
      Logger.info("[KnowledgeSyncer] Processing #{length(memories)} memories")

      results =
        memories
        |> Enum.map(&do_process_memory/1)
        |> Enum.reduce(%{synced: 0, triples: 0, errors: 0}, fn
          {:ok, count}, acc ->
            %{acc | synced: acc.synced + 1, triples: acc.triples + count}

          {:error, _}, acc ->
            %{acc | errors: acc.errors + 1}
        end)

      Logger.info(
        "[KnowledgeSyncer] Sync complete: #{results.synced} memories → #{results.triples} triples (#{results.errors} errors)"
      )

      new_state = %{
        state
        | last_sync: DateTime.utc_now(),
          total_synced: state.total_synced + results.synced,
          total_triples: state.total_triples + results.triples,
          errors: state.errors + results.errors
      }

      {{:ok, results}, new_state}
    end
  end

  defp get_unprocessed_memories do
    # Query memories that:
    # 1. Have high enough importance
    # 2. Haven't been processed for knowledge (no knowledge_synced_at)
    # 3. Are actual content (not entity_anchors which are already knowledge)
    query =
      from(e in Engram,
        where: e.importance >= ^@min_importance,
        where: is_nil(e.knowledge_synced_at),
        where: e.category != "entity_anchor",
        order_by: [desc: e.importance, desc: e.inserted_at],
        limit: ^@batch_size
      )

    Repo.all(query)
  rescue
    # Handle case where knowledge_synced_at column doesn't exist yet
    Ecto.QueryError ->
      Logger.warning("[KnowledgeSyncer] knowledge_synced_at column not found, using fallback query")
      fallback_query()

    error ->
      Logger.error("[KnowledgeSyncer] Query error: #{inspect(error)}")
      []
  end

  defp fallback_query do
    # Fallback for when the column doesn't exist - get recent high-importance memories
    query =
      from(e in Engram,
        where: e.importance >= ^@min_importance,
        where: e.category != "entity_anchor",
        order_by: [desc: e.inserted_at],
        limit: ^@batch_size
      )

    Repo.all(query)
  rescue
    _ -> []
  end

  defp do_process_memory(%Engram{} = memory) do
    content = memory.content || ""

    # Extract relationships using the Ingestor's regex patterns
    case Ingestor.extract_with_regex(content) do
      {:ok, [_ | _] = triples} ->
        # Create triples with memory as source
        source = "memory:#{memory.id}"

        results =
          Enum.map(triples, fn triple ->
            Ingestor.ingest_triple(
              %{
                subject:
                  Map.get(triple, "subject") || Map.get(triple, :subject) ||
                    Map.get(triple, "subject_id") || Map.get(triple, :subject_id),
                predicate:
                  Map.get(triple, "predicate") || Map.get(triple, :predicate) ||
                    Map.get(triple, :pred) || Map.get(triple, "pred"),
                object:
                  Map.get(triple, "object") || Map.get(triple, :object) ||
                    Map.get(triple, "object_id") || Map.get(triple, :object_id)
              },
              source
            )
          end)

        success_count = Enum.count(results, &match?({:ok, _}, &1))

        # Mark memory as processed (if column exists)
        mark_as_processed(memory.id)

        {:ok, success_count}

      {:ok, []} ->
        # No relationships found, but still mark as processed
        mark_as_processed(memory.id)
        {:ok, 0}
    end
  end

  defp mark_as_processed(memory_id) do
    # Try to update with knowledge_synced_at
    # This will silently fail if column doesn't exist
    try do
      from(e in Engram, where: e.id == ^memory_id)
      |> Repo.update_all(set: [knowledge_synced_at: DateTime.utc_now()])
    rescue
      _ -> :ok
    end
  end
end
