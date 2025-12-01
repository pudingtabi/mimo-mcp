defmodule Mimo.Brain.InteractionConsolidator do
  @moduledoc """
  Consolidates recorded Interactions into long-term Engrams using LLM curation.

  Part of SPEC-012 Passive Memory System.

  This GenServer:
  1. Periodically checks for unconsolidated interactions
  2. Batches them and sends to LLMCurator for analysis
  3. Creates Engrams from curator output
  4. Links Engrams to source Interactions
  5. Marks Interactions as consolidated

  ## Configuration

      config :mimo_mcp, :interaction_consolidation,
        enabled: true,
        interval_ms: 60_000,           # Check every minute
        batch_size: 20,                 # Process 20 interactions at a time
        min_interactions: 5,            # Wait for at least 5 before processing
        min_age_minutes: 5              # Interactions must be 5+ minutes old

  ## Architecture (SPEC-012)

  ```
  Tool calls → Interactions table (raw)
       ↓ (periodic)
  InteractionConsolidator
       ↓
  LLMCurator.curate()
       ↓ (importance scoring)
  Engrams table (long-term)
       ↓
  interaction_engrams (link table)
  ```
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Mimo.{Repo, Brain}
  alias Mimo.Brain.{Interaction, Engram, LLMCurator, ThreadManager}

  @default_interval 60_000
  @default_batch_size 20
  @default_min_interactions 5
  @default_min_age_minutes 5

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger immediate consolidation cycle.

  ## Options

    * `:force` - Process even if below min_interactions threshold
    * `:batch_size` - Override default batch size

  ## Returns

    * `{:ok, %{engrams_created: n, interactions_processed: m}}`
  """
  @spec consolidate_now(keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate_now(opts \\ []) do
    GenServer.call(__MODULE__, {:consolidate, opts}, 120_000)
  end

  @doc """
  Get consolidation statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Check if consolidation is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    get_config(:enabled, true)
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_config(:interval_ms, @default_interval))

    state = %{
      last_run: nil,
      total_engrams_created: 0,
      total_interactions_processed: 0,
      last_batch_engrams: 0,
      last_batch_interactions: 0,
      interval: interval,
      failures: 0
    }

    if get_config(:enabled, true) do
      # Delay first run to let system stabilize
      Process.send_after(self(), :consolidate, 30_000)
    end

    Logger.info("InteractionConsolidator initialized (interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call({:consolidate, opts}, _from, state) do
    {result, new_state} = run_consolidation(state, opts)
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    # Get pending count from DB
    pending_count = get_pending_count()

    stats =
      Map.take(state, [
        :last_run,
        :total_engrams_created,
        :total_interactions_processed,
        :last_batch_engrams,
        :last_batch_interactions,
        :failures
      ])
      |> Map.put(:interval_ms, state.interval)
      |> Map.put(:enabled, get_config(:enabled, true))
      |> Map.put(:pending_interactions, pending_count)

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    {_result, new_state} = run_consolidation(state, [])
    schedule_next(state.interval)
    {:noreply, new_state}
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp run_consolidation(state, opts) do
    force = Keyword.get(opts, :force, false)
    batch_size = opts[:batch_size] || get_config(:batch_size, @default_batch_size)
    min_interactions = get_config(:min_interactions, @default_min_interactions)
    min_age_minutes = get_config(:min_age_minutes, @default_min_age_minutes)

    :telemetry.execute(
      [:mimo, :brain, :interaction_consolidation, :started],
      %{count: 1},
      %{force: force}
    )

    # Get unconsolidated interactions older than min_age
    interactions = get_unconsolidated_interactions(batch_size, min_age_minutes)

    # Check if we have enough to process
    if length(interactions) < min_interactions and not force do
      Logger.debug(
        "InteractionConsolidator: only #{length(interactions)} interactions, waiting for #{min_interactions}"
      )

      result = %{engrams_created: 0, interactions_processed: 0, skipped: true}
      {result, state}
    else
      # Run the actual consolidation
      case do_consolidation(interactions) do
        {:ok, engrams_created} ->
          Logger.info(
            "InteractionConsolidator: created #{engrams_created} engrams from #{length(interactions)} interactions"
          )

          :telemetry.execute(
            [:mimo, :brain, :interaction_consolidation, :completed],
            %{engrams_created: engrams_created, interactions_processed: length(interactions)},
            %{}
          )

          result = %{
            engrams_created: engrams_created,
            interactions_processed: length(interactions)
          }

          new_state = %{
            state
            | last_run: DateTime.utc_now(),
              total_engrams_created: state.total_engrams_created + engrams_created,
              total_interactions_processed:
                state.total_interactions_processed + length(interactions),
              last_batch_engrams: engrams_created,
              last_batch_interactions: length(interactions)
          }

          {result, new_state}
      end
    end
  end

  defp do_consolidation([]), do: {:ok, 0}

  defp do_consolidation(interactions) do
    # Get current thread ID for linking
    thread_id =
      case ThreadManager.get_current_thread_id() do
        id when is_binary(id) -> id
        _ -> nil
      end

    # Curate interactions using LLM
    case LLMCurator.curate(interactions) do
      {:ok, []} ->
        # No memories worth creating, but mark as consolidated
        mark_as_consolidated(interactions)
        {:ok, 0}

      {:ok, memory_candidates} ->
        # Create engrams from candidates
        engrams_created =
          memory_candidates
          |> Enum.map(fn candidate ->
            create_engram_from_candidate(candidate, thread_id, interactions)
          end)
          |> Enum.count(fn result -> match?({:ok, _}, result) end)

        # Mark all interactions as consolidated
        mark_as_consolidated(interactions)

        {:ok, engrams_created}
    end
  end

  defp create_engram_from_candidate(candidate, thread_id, all_interactions) do
    # Generate embedding for the curated content
    case Brain.LLM.generate_embedding(candidate.content) do
      {:ok, embedding} when is_list(embedding) and length(embedding) > 0 ->
        # SPEC-031 + SPEC-033: Quantize to int8 and binary for searchability
        {embedding_to_store, quantized_attrs} =
          case Mimo.Vector.Math.quantize_int8(embedding) do
            {:ok, {int8_binary, scale, offset}} ->
              binary_attrs =
                case Mimo.Vector.Math.int8_to_binary(int8_binary) do
                  {:ok, binary} -> %{embedding_binary: binary}
                  {:error, _} -> %{}
                end

              {[],
               Map.merge(
                 %{
                   embedding_int8: int8_binary,
                   embedding_scale: scale,
                   embedding_offset: offset
                 },
                 binary_attrs
               )}

            {:error, reason} ->
              Logger.warning("Int8 quantization failed: #{inspect(reason)}, storing float32")
              {embedding, %{}}
          end

        # Build metadata
        metadata = %{
          "source" => "interaction_consolidation",
          "reasoning" => candidate.reasoning,
          "curated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "source_interaction_count" => length(candidate.source_interaction_ids)
        }

        # Detect project from content
        project_id = Brain.LLM.detect_project(candidate.content)

        # Auto-generate tags
        tags =
          case Brain.LLM.auto_tag(candidate.content) do
            {:ok, t} -> t
            _ -> []
          end

        # Create engram with quantized embedding
        attrs =
          Map.merge(
            %{
              content: candidate.content,
              category: candidate.category,
              importance: candidate.importance,
              original_importance: candidate.importance,
              decay_rate: candidate.decay_rate,
              embedding: embedding_to_store,
              metadata: metadata,
              thread_id: thread_id,
              project_id: project_id,
              tags: tags
            },
            quantized_attrs
          )

        case Repo.insert(Engram.changeset(%Engram{}, attrs)) do
          {:ok, engram} ->
            # Link to source interactions
            link_to_interactions(engram.id, candidate.source_interaction_ids, all_interactions)

            Logger.debug(
              "Created engram #{engram.id} (importance: #{candidate.importance}, category: #{candidate.category})"
            )

            {:ok, engram}

          {:error, changeset} ->
            Logger.error("Failed to create engram: #{inspect(changeset.errors)}")
            {:error, changeset}
        end

      {:ok, []} ->
        Logger.warning("Embedding generation returned empty list for interaction consolidation")
        {:error, :empty_embedding}

      {:error, reason} ->
        Logger.error(
          "Embedding generation failed for interaction consolidation: #{inspect(reason)}"
        )

        {:error, {:embedding_failed, reason}}
    end
  end

  defp link_to_interactions(engram_id, source_ids, all_interactions) do
    # Find matching interaction IDs
    matching_interaction_ids =
      all_interactions
      |> Enum.filter(fn i ->
        id = to_string(i.id)
        id in source_ids
      end)
      |> Enum.map(& &1.id)

    # Insert into join table
    Enum.each(matching_interaction_ids, fn interaction_id ->
      Repo.insert_all(
        "interaction_engrams",
        [%{interaction_id: interaction_id, engram_id: engram_id}],
        on_conflict: :nothing
      )
    end)
  end

  defp mark_as_consolidated(interactions) do
    ids = Enum.map(interactions, & &1.id)

    from(i in Interaction, where: i.id in ^ids)
    |> Repo.update_all(set: [consolidated: true, updated_at: DateTime.utc_now()])
  end

  defp get_unconsolidated_interactions(limit, min_age_minutes) do
    cutoff = DateTime.add(DateTime.utc_now(), -min_age_minutes, :minute)

    from(i in Interaction,
      where: i.consolidated == false,
      where: i.timestamp < ^cutoff,
      order_by: [asc: i.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp get_pending_count do
    from(i in Interaction, where: i.consolidated == false, select: count(i.id))
    |> Repo.one()
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :consolidate, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :interaction_consolidation, [])
    |> Keyword.get(key, default)
  end
end
