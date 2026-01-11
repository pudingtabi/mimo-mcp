defmodule Mimo.SleepCycle do
  @moduledoc """
  SPEC-072: Sleep Cycle - Multi-Stage Memory Consolidation.

  Inspired by biological sleep cycles, this module orchestrates memory
  consolidation across the Triad Memory Stores:

  ## Consolidation Stages

  1. **Episodic → Semantic** (Pattern Extraction)
     - Analyze episodic memories for recurring patterns
     - Extract entities, relationships, concepts
     - Add to knowledge graph (Synapse)

  2. **Semantic → Procedural** (Procedure Codification)
     - Identify repeated action sequences
     - Create/update procedure templates
     - Store in ProceduralStore

  3. **Memory Pruning** (Decay & Cleanup)
     - Apply decay to low-access memories
     - Archive or delete very old, unused memories
     - Optimize storage

  ## Scheduling

  The sleep cycle runs during "quiet periods" - detected when:
  - No tool calls for N minutes
  - System load below threshold
  - Explicitly triggered by admin

  ## References

  - CoALA Framework: Sleep/wake cycles in cognitive architectures
  - SPEC-070: Meta-Cognitive Router (classification)
  - SPEC-071: Active Inference (prediction feedback)
  """

  use GenServer
  require Logger

  alias Mimo.Brain.{Consolidator, HnswIndex, LLM, Memory}
  alias Mimo.Cognitive.FeedbackLoop
  alias Mimo.ProceduralStore
  alias Mimo.Synapse.{EdgePredictor, Graph}

  # Configuration
  # 5 minutes of quiet
  @quiet_period_ms 5 * 60 * 1000
  # Check every minute
  @check_interval_ms 60 * 1000
  # Need at least 3 similar memories
  @min_memories_for_pattern 3

  defstruct [
    :last_activity,
    :cycle_count,
    :stats,
    :quiet_since
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate sleep cycle consolidation.

  ## Options
    - `:stages` - List of stages to run (default: all)
    - `:force` - Run even if not in quiet period (default: false)

  ## Returns
    - `{:ok, results}` - Map with results per stage
    - `{:error, reason}` - If cycle fails
  """
  @spec run_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_cycle(opts \\ []) do
    GenServer.call(__MODULE__, {:run_cycle, opts}, 120_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Record activity to reset quiet period timer.
  Called by tool execution to indicate system is active.
  """
  @spec record_activity() :: :ok
  def record_activity do
    GenServer.cast(__MODULE__, :record_activity)
  end

  @doc """
  Get sleep cycle statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @impl true
  def init(_opts) do
    # Skip sleep cycle in test mode to avoid DB connection pool exhaustion
    if Application.get_env(:mimo_mcp, :disable_sleep_cycle, false) do
      Logger.debug("[SleepCycle] Disabled in test mode")

      {:ok,
       %__MODULE__{
         last_activity: System.monotonic_time(:millisecond),
         cycle_count: 0,
         quiet_since: nil,
         stats: %{}
       }}
    else
      # Schedule periodic quiet period checks
      schedule_check()

      state = %__MODULE__{
        last_activity: System.monotonic_time(:millisecond),
        cycle_count: 0,
        quiet_since: nil,
        stats: %{
          cycles_completed: 0,
          patterns_extracted: 0,
          procedures_created: 0,
          memories_pruned: 0,
          edges_predicted: 0,
          hebbian_edges_cleaned: 0,
          quality_issues_fixed: 0,
          last_cycle_at: nil
        }
      }

      Logger.info("[SleepCycle] Initialized - monitoring for quiet periods")

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:run_cycle, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)

    stages =
      Keyword.get(opts, :stages, [
        :hnsw_health_check,
        :quality_maintenance,
        :episodic_to_semantic,
        :semantic_to_procedural,
        :edge_prediction,
        :hebbian_cleanup,
        :pruning
      ])

    # Check if we should run
    in_quiet_period = quiet_period?(state)

    if force or in_quiet_period do
      Logger.info("[SleepCycle] Starting consolidation cycle (stages: #{inspect(stages)})")

      results = run_stages(stages)

      new_stats = update_stats(state.stats, results)

      new_state = %{
        state
        | cycle_count: state.cycle_count + 1,
          stats: new_stats,
          # Reset quiet period after cycle
          quiet_since: nil
      }

      {:reply, {:ok, results}, new_state}
    else
      {:reply, {:error, :not_in_quiet_period}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    full_stats =
      Map.merge(state.stats, %{
        cycle_count: state.cycle_count,
        in_quiet_period: quiet_period?(state),
        quiet_duration_ms: quiet_duration(state)
      })

    {:reply, full_stats, state}
  end

  @impl true
  def handle_cast(:record_activity, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond), quiet_since: nil}}
  end

  @impl true
  def handle_info(:check_quiet_period, state) do
    new_state = check_and_maybe_run(state)
    schedule_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp run_stages(stages) do
    Enum.reduce(stages, %{}, fn stage, acc ->
      result = run_stage(stage)
      Map.put(acc, stage, result)
    end)
  end

  defp run_stage(:episodic_to_semantic) do
    Logger.debug("[SleepCycle] Running episodic → semantic consolidation")

    try do
      # Get recent episodic memories
      memories = Memory.search_memories("*", limit: 100, category: "observation")

      # NEW: Also analyze feedback patterns for learning insights
      feedback_memories = get_feedback_patterns()

      # Group by similarity to find patterns
      patterns = find_patterns(memories)

      # NEW: Use LLM for deeper pattern analysis if we have significant patterns
      enriched_patterns =
        if length(patterns) >= 2 do
          enrich_patterns_with_llm(patterns)
        else
          patterns
        end

      # Extract entities and relationships from patterns
      extracted = Enum.map(enriched_patterns, &extract_to_semantic/1)
      successful = Enum.count(extracted, fn {status, _} -> status == :ok end)

      # NEW: Extract learning insights from feedback
      feedback_insights = extract_feedback_insights(feedback_memories)

      %{
        memories_analyzed: length(memories),
        patterns_found: length(patterns),
        entities_extracted: successful,
        feedback_insights: length(feedback_insights),
        llm_enriched: length(patterns) >= 2
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Episodic→Semantic failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  defp run_stage(:semantic_to_procedural) do
    Logger.debug("[SleepCycle] Running semantic → procedural consolidation")

    try do
      # Look for action patterns in memories
      action_memories =
        Memory.search_memories(
          "implement OR fix OR create OR build",
          limit: 50,
          category: "action"
        )

      # Identify repeated workflows
      workflows = identify_workflows(action_memories)

      # Create/update procedures
      procedures_created = Enum.count(workflows, &create_procedure/1)

      %{
        actions_analyzed: length(action_memories),
        workflows_found: length(workflows),
        procedures_created: procedures_created
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Semantic→Procedural failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  defp run_stage(:hebbian_cleanup) do
    Logger.debug("[SleepCycle] Running Hebbian edge cleanup (SPEC-092)")

    try do
      alias Mimo.Brain.HebbianLearner

      # Clean up stale edges older than 7 days with no access
      {:ok, deleted} = HebbianLearner.cleanup_stale_edges(max_age_days: 7)

      %{
        edges_deleted: deleted,
        max_age_days: 7
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Hebbian cleanup failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  defp run_stage(:pruning) do
    Logger.debug("[SleepCycle] Running memory pruning")

    try do
      # Run consolidator's cleanup (decay is handled internally)
      {:ok, consolidated} = Consolidator.consolidate_now(force: false)

      %{
        consolidated: consolidated
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Pruning failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  defp run_stage(:edge_prediction) do
    Logger.debug("[SleepCycle] Running edge prediction (pattern completion)")

    try do
      # Get prediction stats before
      stats_before = EdgePredictor.stats()

      # Materialize predicted edges based on embedding similarity
      # This implements hippocampal pattern completion during "sleep"
      {:ok, edges_created} =
        EdgePredictor.materialize_predictions(
          # High confidence threshold
          min_similarity: 0.75,
          # Limit per cycle
          max_edges: 25
        )

      Logger.info("[SleepCycle] EdgePredictor created #{edges_created} new edges")

      %{
        edges_created: edges_created,
        engrams_analyzed: stats_before.engrams_with_embeddings,
        similarity_threshold: 0.75
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Edge prediction failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  defp run_stage(:hnsw_health_check) do
    Logger.info("[SleepCycle] Running HNSW health check...")

    case HnswIndex.rebuild_if_needed() do
      :ok ->
        %{status: :healthy, action: :none}

      {:rebuilt, count} ->
        Logger.info("[SleepCycle] HNSW index rebuilt with #{count} vectors")
        %{status: :rebuilt, vectors: count}

      {:error, reason} ->
        Logger.error("[SleepCycle] HNSW health check failed: #{inspect(reason)}")
        %{status: :error, reason: inspect(reason)}
    end
  end

  # Phase 2 Q7: Automated Quality Maintenance
  # Runs during each sleep cycle to detect and fix memory quality issues
  @min_entity_anchor_length 50
  @stale_anchor_days 30

  defp run_stage(:quality_maintenance) do
    Logger.info("[SleepCycle] Running quality maintenance...")

    try do
      alias Mimo.Repo
      alias Mimo.Brain.Engram
      import Ecto.Query

      # 1. Count and log current quality metrics
      quality_stats =
        Repo.all(
          from(e in Engram,
            where: e.category == "entity_anchor",
            select: {count(e.id), avg(fragment("LENGTH(content)"))}
          )
        )

      {anchor_count, anchor_avg_len} = List.first(quality_stats) || {0, 0}

      # 2. Delete stale entity anchors not accessed in 30+ days
      stale_cutoff = DateTime.utc_now() |> DateTime.add(-@stale_anchor_days, :day)

      {stale_deleted, _} =
        Repo.delete_all(
          from(e in Engram,
            where: e.category == "entity_anchor",
            where: e.last_accessed_at < ^stale_cutoff or is_nil(e.last_accessed_at),
            where: fragment("LENGTH(content)") < @min_entity_anchor_length
          )
        )

      # 3. Check for synthesis duplicates
      synthesis_dups =
        Repo.one(
          from(e in Engram,
            where: like(e.content, "%[Synthesized Insight]%"),
            group_by: e.content,
            having: count(e.id) > 1,
            select: count()
          )
        ) || 0

      Logger.info(
        "[SleepCycle] Quality maintenance: anchors=#{anchor_count} (avg #{round_safe(anchor_avg_len)} chars), stale_deleted=#{stale_deleted}, dup_syntheses=#{synthesis_dups}"
      )

      %{
        entity_anchors: anchor_count,
        avg_anchor_length: round_safe(anchor_avg_len),
        stale_anchors_deleted: stale_deleted,
        duplicate_syntheses_detected: synthesis_dups,
        status: :completed
      }
    rescue
      e ->
        Logger.warning("[SleepCycle] Quality maintenance failed: #{Exception.message(e)}")
        %{error: Exception.message(e)}
    end
  end

  # Catch-all clause for unknown stages (must be grouped with other run_stage clauses)
  defp run_stage(unknown) do
    %{error: "Unknown stage: #{inspect(unknown)}"}
  end

  defp round_safe(nil), do: 0
  defp round_safe(val) when is_float(val), do: Float.round(val, 1)
  defp round_safe(val), do: val

  defp find_patterns(memories) when is_list(memories) do
    # Simple pattern finding: group memories by similar content
    memories
    |> Enum.group_by(&extract_topic/1)
    |> Enum.filter(fn {_topic, mems} -> length(mems) >= @min_memories_for_pattern end)
    |> Enum.map(fn {topic, mems} ->
      %{
        topic: topic,
        memories: mems,
        count: length(mems),
        example: List.first(mems)
      }
    end)
  end

  defp extract_topic(memory) do
    content = memory.content || ""
    # Extract first significant phrase as topic
    content
    |> String.split(~r/[.!?\n]/, parts: 2)
    |> List.first()
    |> String.slice(0, 50)
    |> String.trim()
  end

  defp extract_to_semantic(%{topic: topic, memories: memories}) do
    try do
      # Extract entities from the pattern
      entities = extract_entities(topic)

      # Create nodes in knowledge graph for each entity
      created_nodes =
        Enum.map(entities, fn entity ->
          Graph.find_or_create_node(:concept, entity, %{
            source: "sleep_cycle",
            extracted_from: "episodic_pattern",
            memory_count: length(memories)
          })
        end)

      # Create relationships between entities if multiple found
      if length(entities) > 1 do
        [first | rest] = entities

        Enum.each(rest, fn other ->
          create_relationship(first, other, "relates_to")
        end)
      end

      {:ok, %{entities: entities, nodes: length(created_nodes)}}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp extract_entities(text) do
    # Extract PascalCase names (modules/classes)
    pascal_case =
      Regex.scan(~r/\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b/, text)
      |> Enum.map(fn [_, match] -> match end)

    # Extract quoted identifiers
    quoted =
      Regex.scan(~r/"([^"]+)"/, text)
      |> Enum.map(fn [_, match] -> match end)

    # Extract key terms (capitalized words)
    key_terms =
      Regex.scan(~r/\b([A-Z][a-z]{2,})\b/, text)
      |> Enum.map(fn [_, match] -> match end)

    (pascal_case ++ quoted ++ key_terms)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp create_relationship(source, target, predicate) do
    with {:ok, source_node} <- Graph.find_or_create_node(:concept, source),
         {:ok, target_node} <- Graph.find_or_create_node(:concept, target) do
      Graph.create_edge(%{
        source_node_id: source_node.id,
        target_node_id: target_node.id,
        edge_type: String.to_atom(predicate),
        properties: %{source: "sleep_cycle"}
      })
    end
  rescue
    _ -> :ok
  end

  defp identify_workflows(memories) when is_list(memories) do
    # Group by action type
    memories
    |> Enum.filter(&action_memory?/1)
    |> Enum.group_by(&extract_action_type/1)
    |> Enum.filter(fn {_type, mems} -> length(mems) >= 2 end)
    |> Enum.map(fn {action_type, mems} ->
      %{
        action_type: action_type,
        occurrences: length(mems),
        examples: Enum.take(mems, 3)
      }
    end)
  end

  defp action_memory?(memory) do
    content = memory.content || ""
    String.contains?(String.downcase(content), ["implement", "fix", "create", "build", "run"])
  end

  defp extract_action_type(memory) do
    content = String.downcase(memory.content || "")

    cond do
      String.contains?(content, "fix") -> :debug
      String.contains?(content, "implement") -> :implement
      String.contains?(content, "create") -> :create
      String.contains?(content, "test") -> :test
      String.contains?(content, "build") -> :build
      true -> :general
    end
  end

  defp create_procedure(%{action_type: action_type, occurrences: occurrences, examples: examples}) do
    # Only process if we have enough examples
    if occurrences >= 3 do
      procedure_name = "auto_#{action_type}_workflow"

      # Check if procedure already exists using load
      case ProceduralStore.Loader.load(procedure_name, "latest") do
        {:ok, _existing} ->
          # Already exists, skip
          false

        {:error, :not_found} ->
          # Log the pattern for manual procedure creation
          # (ProceduralStore doesn't support programmatic creation yet)
          Logger.info(
            "[SleepCycle] Detected workflow pattern: #{procedure_name} (#{occurrences} occurrences)"
          )

          # STABILITY FIX: Check if we already stored a memory for this pattern
          # to prevent duplicate auto-detected workflow memories (was creating 50+ duplicates)
          # NOTE: Using direct SQL query with LIKE instead of Memory.search() because
          # vector search can fail when HNSW index is out of sync, causing duplicates.
          existing_pattern_memory =
            case Mimo.Repo.query(
                   "SELECT 1 FROM engrams WHERE content LIKE ? LIMIT 1",
                   ["%[Auto-detected workflow pattern]%Name: #{procedure_name}%"]
                 ) do
              {:ok, %{num_rows: n}} when n > 0 -> true
              _ -> false
            end

          if existing_pattern_memory do
            Logger.debug(
              "[SleepCycle] Pattern #{procedure_name} already stored in memory, skipping"
            )

            false
          else
            # Store as a memory for future reference
            steps = extract_steps_from_examples(examples)

            content = """
            [Auto-detected workflow pattern]
            Name: #{procedure_name}
            Occurrences: #{occurrences}
            Steps: #{inspect(steps)}
            """

            Memory.store(%{content: content, category: "plan", importance: 0.7})
            true
          end

        _ ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp extract_steps_from_examples(examples) do
    # Simple step extraction - just use the first example's content
    example = List.first(examples)
    content = (example && example.content) || ""

    # Split into lines and create basic steps
    content
    |> String.split("\n")
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.take(5)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      %{
        order: idx,
        action: String.trim(line),
        type: "manual"
      }
    end)
  end

  defp quiet_period?(state) do
    quiet_duration(state) >= @quiet_period_ms
  end

  defp quiet_duration(state) do
    now = System.monotonic_time(:millisecond)
    now - state.last_activity
  end

  defp check_and_maybe_run(state) do
    if quiet_period?(state) and should_run_cycle?(state) do
      Logger.info("[SleepCycle] Quiet period detected - running automatic consolidation")

      # Run in background to not block
      spawn(fn ->
        run_cycle(force: true)
      end)

      %{state | quiet_since: System.monotonic_time(:millisecond)}
    else
      # Mark when quiet period started
      if quiet_duration(state) > 0 and is_nil(state.quiet_since) do
        %{state | quiet_since: System.monotonic_time(:millisecond)}
      else
        state
      end
    end
  end

  defp should_run_cycle?(state) do
    # Don't run too frequently
    case state.stats.last_cycle_at do
      nil ->
        true

      last_time ->
        time_since = DateTime.diff(DateTime.utc_now(), last_time, :millisecond)
        time_since > @quiet_period_ms * 2
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_quiet_period, @check_interval_ms)
  end

  defp update_stats(stats, results) do
    patterns = get_in(results, [:hnsw_health_check, :episodic_to_semantic, :patterns_found]) || 0
    procedures = get_in(results, [:semantic_to_procedural, :procedures_created]) || 0
    pruned = get_in(results, [:pruning, :consolidated]) || 0
    edges = get_in(results, [:edge_prediction, :edges_created]) || 0
    hebbian_cleaned = get_in(results, [:hebbian_cleanup, :edges_deleted]) || 0
    quality_fixed = get_in(results, [:quality_maintenance, :stale_anchors_deleted]) || 0

    %{
      stats
      | cycles_completed: stats.cycles_completed + 1,
        patterns_extracted: stats.patterns_extracted + patterns,
        procedures_created: stats.procedures_created + procedures,
        memories_pruned: stats.memories_pruned + pruned,
        edges_predicted: stats.edges_predicted + edges,
        hebbian_edges_cleaned: stats.hebbian_edges_cleaned + hebbian_cleaned,
        quality_issues_fixed: stats.quality_issues_fixed + quality_fixed,
        last_cycle_at: DateTime.utc_now()
    }
  end

  @doc false
  # Get feedback patterns from FeedbackLoop for learning analysis
  defp get_feedback_patterns do
    try do
      FeedbackLoop.get_recent_feedback(limit: 50)
    rescue
      _ -> []
    end
  end

  @doc false
  # Use LLM to enrich patterns with deeper semantic understanding
  defp enrich_patterns_with_llm(patterns) do
    # Prepare pattern summaries for LLM analysis
    pattern_summaries =
      patterns
      |> Enum.take(5)
      |> Enum.map_join("\n", fn p ->
        "- Topic: #{p.topic} (#{p.count} occurrences)"
      end)

    prompt = """
    Analyze these memory patterns and identify:
    1. Key concepts/entities to track
    2. Relationships between concepts
    3. Potential procedures/workflows implied

    Patterns:
    #{pattern_summaries}

    Respond in JSON format:
    {"concepts": ["concept1"], "relationships": [{"from": "A", "to": "B", "type": "relates_to"}], "workflows": ["workflow_name"]}
    """

    case LLM.complete(prompt, max_tokens: 300, timeout: 5000) do
      {:ok, response} ->
        case parse_llm_insights(response) do
          {:ok, insights} ->
            # Enrich patterns with LLM insights
            Enum.map(patterns, fn pattern ->
              Map.put(pattern, :llm_insights, insights)
            end)

          _ ->
            patterns
        end

      {:error, _} ->
        # LLM unavailable, fall back to basic patterns
        patterns
    end
  rescue
    _ -> patterns
  end

  defp parse_llm_insights(response) do
    # Try to extract JSON from response
    json_match = Regex.run(~r/\{[^{}]*\}/, response)

    case json_match do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> {:error, :invalid_json}
        end

      _ ->
        {:error, :no_json_found}
    end
  end

  @doc false
  # Extract learning insights from feedback data
  defp extract_feedback_insights(feedback_entries) do
    # Group feedback by category and success rate
    feedback_entries
    |> Enum.group_by(& &1.category)
    |> Enum.flat_map(fn {category, entries} ->
      total = length(entries)
      successful = Enum.count(entries, & &1.success)
      success_rate = if total > 0, do: successful / total, else: 0

      if total >= 5 do
        # We have enough data to extract insights
        [
          %{
            category: category,
            total_feedback: total,
            success_rate: success_rate,
            insight: generate_insight(category, success_rate),
            # Low success = needs improvement
            actionable: success_rate < 0.6
          }
        ]
      else
        []
      end
    end)
  end

  defp generate_insight(category, success_rate) when success_rate < 0.4 do
    "#{category} predictions have low accuracy (#{Float.round(success_rate * 100, 1)}%) - needs model adjustment"
  end

  defp generate_insight(category, success_rate) when success_rate < 0.7 do
    "#{category} predictions are moderate (#{Float.round(success_rate * 100, 1)}%) - continue monitoring"
  end

  defp generate_insight(category, success_rate) do
    "#{category} predictions are performing well (#{Float.round(success_rate * 100, 1)}%)"
  end
end
