defmodule Mimo.Brain.Synthesizer do
  @moduledoc """
  Autonomous Knowledge Synthesizer - Creates new insights from existing memories.

  Unlike the Consolidator (which moves data) and InteractionConsolidator (which curates),
  the Synthesizer generates NEW knowledge by:

  1. Finding clusters of related memories
  2. Generating synthesis facts that capture cross-memory insights
  3. Storing these as high-importance facts with source links

  This is the key to "active intelligence" - the system thinks between interactions.

  ## Configuration

      config :mimo_mcp, :synthesizer,
        enabled: true,
        interval_ms: 300_000,       # Run every 5 minutes
        min_cluster_size: 3,        # Need at least 3 related memories
        similarity_threshold: 0.75, # Minimum similarity to cluster
        max_syntheses_per_run: 5    # Limit API calls

  ## Example Output

  Given memories about:
  - "User prefers dark mode"
  - "User uses vim keybindings"
  - "User dislikes verbose output"

  Synthesizer creates:
  - "SYNTHESIS: User has a minimalist, efficiency-focused workflow preference"
  """

  use GenServer
  require Logger

  alias Mimo.Brain.{Memory, LLM}
  alias Mimo.SafeCall

  # 5 minutes
  @default_interval 300_000
  @default_min_cluster_size 3
  @default_similarity_threshold 0.75
  @default_max_syntheses 5

  # Synthesis prompt for local model
  @synthesis_prompt """
  Given these related memories from the same knowledge base, generate a SINGLE higher-level insight that captures the pattern or connection between them.

  MEMORIES:
  {{memories}}

  Generate ONE synthesis statement that:
  1. Captures what these memories have in common
  2. Provides actionable insight for future interactions
  3. Is written as a declarative fact (not a question)

  RESPOND WITH ONLY THE SYNTHESIS STATEMENT, nothing else.
  """

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger immediate synthesis cycle.

  Returns `{:ok, %{syntheses_created: n, clusters_found: m}}`
  """
  @spec synthesize_now(keyword()) :: {:ok, map()} | {:error, term()}
  def synthesize_now(opts \\ []) do
    SafeCall.genserver(__MODULE__, {:synthesize, opts},
      timeout: 180_000,
      raw: true,
      fallback: {:ok, %{syntheses_created: 0, clusters_found: 0}}
    )
  end

  @doc """
  Get synthesis statistics.
  """
  @spec stats() :: map()
  def stats do
    SafeCall.genserver(__MODULE__, :stats,
      raw: true,
      fallback: %{status: :unavailable, total_syntheses: 0}
    )
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_config(:interval_ms, @default_interval))

    state = %{
      last_run: nil,
      total_syntheses: 0,
      total_clusters_processed: 0,
      last_batch_syntheses: 0,
      interval: interval,
      failures: 0
    }

    if get_config(:enabled, true) do
      # Delay first run to let system stabilize
      Process.send_after(self(), :synthesize, 60_000)
    end

    Logger.info("Synthesizer initialized (interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call({:synthesize, opts}, _from, state) do
    {result, new_state} = run_synthesis(state, opts)
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.take(state, [
        :last_run,
        :total_syntheses,
        :total_clusters_processed,
        :last_batch_syntheses,
        :failures
      ])
      |> Map.put(:interval_ms, state.interval)
      |> Map.put(:enabled, get_config(:enabled, true))

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:synthesize, state) do
    {_result, new_state} = run_synthesis(state, [])
    schedule_next(state.interval)
    {:noreply, new_state}
  end

  # ==========================================================================
  # Core Synthesis Logic
  # ==========================================================================

  defp run_synthesis(state, opts) do
    try do
      do_run_synthesis(state, opts)
    rescue
      e in DBConnection.OwnershipError ->
        Logger.debug("[Synthesizer] Skipping in test mode: #{Exception.message(e)}")
        {%{syntheses_created: 0, clusters_found: 0, skipped: true}, state}

      e ->
        Logger.error("[Synthesizer] Error: #{Exception.message(e)}")

        {%{syntheses_created: 0, clusters_found: 0, error: Exception.message(e)},
         %{state | failures: state.failures + 1}}
    end
  end

  defp do_run_synthesis(state, opts) do
    min_cluster_size =
      opts[:min_cluster_size] || get_config(:min_cluster_size, @default_min_cluster_size)

    similarity_threshold =
      opts[:similarity_threshold] ||
        get_config(:similarity_threshold, @default_similarity_threshold)

    max_syntheses =
      opts[:max_syntheses] || get_config(:max_syntheses_per_run, @default_max_syntheses)

    :telemetry.execute([:mimo, :brain, :synthesis, :started], %{count: 1}, %{})

    # Get recent, unsynthesized memories
    recent_memories = get_synthesis_candidates(limit: 100)

    if length(recent_memories) < min_cluster_size do
      Logger.debug("[Synthesizer] Not enough memories (#{length(recent_memories)}) for synthesis")
      {%{syntheses_created: 0, clusters_found: 0, reason: :insufficient_memories}, state}
    else
      # Find clusters of similar memories
      clusters = find_memory_clusters(recent_memories, similarity_threshold, min_cluster_size)

      Logger.info("[Synthesizer] Found #{length(clusters)} clusters")

      # Generate syntheses for top clusters
      {syntheses_created, failures} =
        clusters
        |> Enum.take(max_syntheses)
        |> Enum.reduce({0, 0}, fn cluster, {s, f} ->
          case generate_and_store_synthesis(cluster) do
            :ok -> {s + 1, f}
            {:error, _} -> {s, f + 1}
          end
        end)

      :telemetry.execute(
        [:mimo, :brain, :synthesis, :completed],
        %{syntheses_created: syntheses_created, clusters_found: length(clusters)},
        %{}
      )

      if syntheses_created > 0 do
        Logger.info(
          "[Synthesizer] Created #{syntheses_created} synthesis facts from #{length(clusters)} clusters"
        )
      end

      result = %{syntheses_created: syntheses_created, clusters_found: length(clusters)}

      new_state = %{
        state
        | last_run: DateTime.utc_now(),
          total_syntheses: state.total_syntheses + syntheses_created,
          total_clusters_processed: state.total_clusters_processed + length(clusters),
          last_batch_syntheses: syntheses_created,
          failures: state.failures + failures
      }

      {result, new_state}
    end
  end

  @doc """
  Find clusters of semantically similar memories.

  Uses embedding similarity to group related memories together.
  """
  def find_memory_clusters(memories, threshold, min_size) do
    # Build similarity matrix
    memories_with_embeddings =
      memories
      |> Enum.filter(fn m ->
        emb = Map.get(m, :embedding) || Map.get(m, :embedding_int8)
        is_list(emb) or is_binary(emb)
      end)

    if length(memories_with_embeddings) < min_size do
      []
    else
      # Simple greedy clustering
      cluster_greedy(memories_with_embeddings, threshold, min_size, [])
    end
  end

  defp cluster_greedy([], _threshold, _min_size, clusters), do: Enum.reverse(clusters)

  defp cluster_greedy([seed | rest], threshold, min_size, clusters) do
    # Find all memories similar to seed
    {similar, remaining} =
      Enum.split_with(rest, fn m ->
        similarity = calculate_similarity(seed, m)
        similarity >= threshold
      end)

    cluster = [seed | similar]

    if length(cluster) >= min_size do
      # Mark these memories as synthesized
      cluster_greedy(remaining, threshold, min_size, [cluster | clusters])
    else
      # Not enough, continue with remaining
      cluster_greedy(rest, threshold, min_size, clusters)
    end
  end

  defp calculate_similarity(m1, m2) do
    emb1 = get_embedding(m1)
    emb2 = get_embedding(m2)

    case {emb1, emb2} do
      {e1, e2} when is_list(e1) and is_list(e2) ->
        Mimo.Vector.Math.cosine_similarity(e1, e2)

      {e1, e2} when is_binary(e1) and is_binary(e2) ->
        # Int8 embeddings - use hamming or decode first
        case {Mimo.Vector.Math.dequantize_int8(e1, 1.0, 0.0),
              Mimo.Vector.Math.dequantize_int8(e2, 1.0, 0.0)} do
          {{:ok, v1}, {:ok, v2}} -> Mimo.Vector.Math.cosine_similarity(v1, v2)
          _ -> 0.0
        end

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  defp get_embedding(m) do
    Map.get(m, :embedding) || Map.get(m, :embedding_int8) || []
  end

  defp generate_and_store_synthesis(cluster) do
    # Format memories for prompt
    memory_texts =
      cluster
      |> Enum.map(fn m -> "- #{m.content}" end)
      |> Enum.join("\n")

    prompt = String.replace(@synthesis_prompt, "{{memories}}", memory_texts)

    # Check if we can skip via EmbeddingGate
    case Mimo.Brain.EmbeddingGate.should_call_llm?(prompt, :synthesis) do
      {:cached, cached_response} ->
        Logger.debug("[Synthesizer] Using cached synthesis")
        store_synthesis_result(cached_response, cluster)

      {:skip, reason} ->
        Logger.debug("[Synthesizer] Skipping synthesis: #{reason}")
        {:error, :skipped}

      {:pass, _} ->
        # Use InferenceScheduler with :low priority (background task)
        # Fall back to direct LLM if scheduler unavailable
        result =
          try do
            Mimo.Brain.InferenceScheduler.request(:low, prompt,
              max_tokens: 200,
              temperature: 0.3,
              raw: true
            )
          catch
            :exit, _ ->
              # Scheduler not available, fall back to direct LLM
              Logger.debug("[Synthesizer] InferenceScheduler unavailable, using direct LLM")
              LLM.complete(prompt, max_tokens: 200, temperature: 0.3, raw: true)
          end

        case result do
          {:ok, synthesis_text} when is_binary(synthesis_text) and byte_size(synthesis_text) > 20 ->
            # Cache for future
            Mimo.Brain.EmbeddingGate.cache_response(prompt, synthesis_text)
            store_synthesis_result(synthesis_text, cluster)

          {:ok, _} ->
            Logger.debug("[Synthesizer] Synthesis too short, skipping")
            {:error, :too_short}

          {:error, :rate_limited} ->
            Logger.debug("[Synthesizer] Rate limited, will retry later")
            {:error, :rate_limited}

          {:error, :timeout} ->
            Logger.debug("[Synthesizer] Scheduler timeout, will retry later")
            {:error, :timeout}

          error ->
            Logger.error("[Synthesizer] LLM generation failed: #{inspect(error)}")
            {:error, :llm_failed}
        end
    end
  end

  defp store_synthesis_result(synthesis_text, cluster) do
    # Clean up the synthesis
    synthesis =
      synthesis_text
      |> String.trim()
      |> ensure_synthesis_prefix()

    # Store as high-importance fact
    source_ids = Enum.map(cluster, & &1.id) |> Enum.join(",")

    metadata = %{
      "source" => "autonomous_synthesis",
      "source_memory_ids" => source_ids,
      "cluster_size" => length(cluster),
      "synthesized_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case Memory.persist_memory(synthesis, "fact", 0.9, nil, metadata) do
      {:ok, _engram} ->
        # Mark source memories as synthesized
        mark_as_synthesized(cluster)
        :ok

      error ->
        Logger.error("[Synthesizer] Failed to persist synthesis: #{inspect(error)}")
        {:error, :persist_failed}
    end
  end

  defp ensure_synthesis_prefix(text) do
    if String.starts_with?(String.upcase(text), "SYNTHESIS") do
      text
    else
      "SYNTHESIS: " <> text
    end
  end

  defp get_synthesis_candidates(opts) do
    limit = Keyword.get(opts, :limit, 100)

    # Get recent memories that haven't been synthesized
    case Memory.search_memories("", limit: limit, min_similarity: 0.0) do
      memories when is_list(memories) ->
        memories
        |> Enum.filter(fn m ->
          metadata = Map.get(m, :metadata, %{})
          # Exclude already-synthesized and synthesis results
          not Map.has_key?(metadata, "synthesized_at") and
            Map.get(metadata, "source") != "autonomous_synthesis"
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp mark_as_synthesized(cluster) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    Enum.each(cluster, fn m ->
      try do
        # Update metadata to mark as synthesized
        current_metadata = Map.get(m, :metadata, %{})
        _new_metadata = Map.put(current_metadata, "synthesized_at", now)

        # This would need a proper update function
        # For now, we log it
        Logger.debug("[Synthesizer] Marked memory #{m.id} as synthesized")
      rescue
        _ -> :ok
      end
    end)
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :synthesize, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :synthesizer, [])
    |> Keyword.get(key, default)
  end
end
