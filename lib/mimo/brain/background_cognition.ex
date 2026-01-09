defmodule Mimo.Brain.BackgroundCognition do
  @moduledoc """
  SPEC-XXX: Background Cognitive Processes - The Persistence Layer.

  This module extends Mimo's cognition ACROSS TIME by running intelligent
  processes when the primary agent (Claude) is not present.

  ## Philosophy

  Claude is ephemeral - exists only during conversations. But Mimo persists.
  This module is Mimo's "brain between sessions" - the part that keeps
  thinking, consolidating, and learning when the user isn't actively chatting.

  ## Core Processes

  1. **Deep Consolidation** - Use LLM to find non-obvious patterns in memories
  2. **Emergence Enhancement** - Use LLM to propose new pattern categories
  3. **Context Pre-computation** - Prepare rich context for next session
  4. **Decay Intelligence** - Use LLM to decide what's worth keeping vs forgetting
  5. **Knowledge Synthesis** - Connect disparate memories into coherent insights
  6. **Knowledge Promotion** - Promote mature patterns up the Knowledge Ladder

  ## Rate Limiting Strategy

  With ~90 RPM total across providers (Cerebras 30, Groq 30, OpenRouter 30),
  we use a conservative approach:
  - Batch operations to minimize calls
  - 10-second minimum gap between calls (6 RPM max per process)
  - Prioritize high-value operations
  - Cache results to avoid redundant calls

  ## Scheduling

  Triggered by:
  - SleepCycle detecting quiet period (5+ min of no activity)
  - Emergence.Scheduler (every 6 hours)
  - Explicit admin trigger

  Does NOT run during active sessions (detected by last_activity < 30s).
  """
  use GenServer
  require Logger

  alias Mimo.Brain.{LLM, Memory}

  # alias Mimo.Brain.DecayScorer  # Commented out - will be used when decay_intelligence is reactivated
  alias Mimo.Brain.Emergence.{Pattern, Promoter}
  alias Mimo.SemanticStore.Ingestor
  alias Mimo.Synapse.Graph
  alias Mimo.Upgrade.Skill, as: UpgradeSkill

  # Configuration
  # 30 seconds of no activity = session ended
  @session_ended_threshold_ms 30 * 1000
  # 10 seconds between LLM calls (conservative)
  @llm_call_interval_ms 10 * 1000
  # Max LLM calls per background cycle
  @max_llm_calls_per_cycle 10
  # Check for idle every 2 minutes
  @idle_check_interval_ms 2 * 60 * 1000
  # 24 hours between knowledge synthesis runs
  @synthesis_interval_ms 24 * 60 * 60 * 1000

  defstruct [
    :last_activity,
    :last_cycle_at,
    :last_synthesis_at,
    :cycle_count,
    :llm_calls_this_cycle,
    :running,
    :stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Record that the user/agent is active. Prevents background cognition.
  Called by tool execution.
  """
  @spec record_activity() :: :ok
  def record_activity do
    GenServer.cast(__MODULE__, :record_activity)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Trigger an immediate background cognition cycle.
  Useful for testing or admin intervention.
  """
  @spec run_now(keyword()) :: {:ok, map()} | {:error, term()}
  def run_now(opts \\ []) do
    GenServer.call(__MODULE__, {:run_now, opts}, 120_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Get background cognition statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Check if a session is currently active.
  """
  @spec session_active?() :: boolean()
  def session_active? do
    GenServer.call(__MODULE__, :session_active?)
  catch
    # Assume active if unavailable (safety)
    :exit, _ -> true
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    schedule_idle_check()

    state = %__MODULE__{
      last_activity: System.monotonic_time(:millisecond),
      last_cycle_at: nil,
      last_synthesis_at: nil,
      cycle_count: 0,
      llm_calls_this_cycle: 0,
      running: false,
      stats: %{
        cycles_completed: 0,
        deep_consolidations: 0,
        patterns_enhanced: 0,
        contexts_precomputed: 0,
        decay_decisions: 0,
        syntheses_created: 0,
        patterns_promoted: 0,
        upgrade_recommendations: 0,
        llm_calls_total: 0,
        last_error: nil
      }
    }

    Logger.info("[BackgroundCognition] Initialized - monitoring for session end")
    {:ok, state}
  end

  @impl true
  def handle_cast(:record_activity, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_call({:run_now, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)

    if state.running do
      {:reply, {:error, :already_running}, state}
    else
      if force or session_ended?(state) do
        {result, new_state} = run_background_cycle(state)
        {:reply, result, new_state}
      else
        {:reply, {:error, :session_active}, state}
      end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    full_stats =
      Map.merge(state.stats, %{
        cycle_count: state.cycle_count,
        running: state.running,
        session_active: not session_ended?(state),
        time_since_activity_ms: time_since_activity(state),
        last_cycle_at: state.last_cycle_at
      })

    {:reply, full_stats, state}
  end

  @impl true
  def handle_call(:session_active?, _from, state) do
    {:reply, not session_ended?(state), state}
  end

  @impl true
  def handle_info(:check_idle, state) do
    new_state =
      if session_ended?(state) and not state.running and should_run_cycle?(state) do
        Logger.info("[BackgroundCognition] Session ended - starting background cycle")
        {_result, updated_state} = run_background_cycle(state)
        updated_state
      else
        state
      end

    schedule_idle_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Core Background Processes
  # ============================================================================

  defp run_background_cycle(state) do
    state = %{state | running: true, llm_calls_this_cycle: 0}
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[BackgroundCognition] Starting background cognitive cycle")

    # Run processes in priority order, respecting LLM budget
    {results, state} =
      state
      |> run_process(:deep_consolidation)
      |> run_process(:emergence_enhancement)
      |> run_process(:context_precomputation)
      |> run_process(:decay_intelligence)
      |> run_process(:knowledge_synthesis)
      |> run_process(:knowledge_promotion)
      |> run_process(:upgrade_analysis)
      |> finalize_results()

    duration_ms = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "[BackgroundCognition] Cycle completed in #{duration_ms}ms, " <>
        "#{state.llm_calls_this_cycle} LLM calls"
    )

    new_stats = update_stats(state.stats, results, state.llm_calls_this_cycle)

    final_state = %{
      state
      | running: false,
        cycle_count: state.cycle_count + 1,
        last_cycle_at: DateTime.utc_now(),
        stats: new_stats
    }

    {{:ok, results}, final_state}
  rescue
    e ->
      Logger.error("[BackgroundCognition] Cycle failed: #{Exception.message(e)}")

      {{:error, Exception.message(e)},
       %{state | running: false, stats: %{state.stats | last_error: Exception.message(e)}}}
  end

  defp run_process({results, state}, process_name) do
    if state.llm_calls_this_cycle >= @max_llm_calls_per_cycle do
      # Budget exhausted, skip remaining processes
      {Map.put(results, process_name, %{skipped: :budget_exhausted}), state}
    else
      {result, new_state} = execute_process(process_name, state)
      {Map.put(results, process_name, result), new_state}
    end
  end

  defp run_process(state, process_name) do
    run_process({%{}, state}, process_name)
  end

  defp finalize_results({results, state}), do: {results, state}

  # ============================================================================
  # Process 1: Deep Consolidation
  # ============================================================================

  defp execute_process(:deep_consolidation, state) do
    Logger.debug("[BackgroundCognition] Running deep consolidation")

    try do
      # Get recent memories that haven't been deeply analyzed
      memories = Memory.search_memories("*", limit: 50)

      if length(memories) >= 5 do
        # Batch memories for LLM analysis
        memory_batch =
          memories
          |> Enum.take(10)
          |> Enum.map_join("\n", fn m -> "- #{m.content}" end)

        prompt = """
        Analyze these memories and identify:
        1. Non-obvious connections between seemingly unrelated items
        2. Implicit patterns that span multiple memories
        3. Key concepts worth tracking as entities

        Memories:
        #{memory_batch}

        Respond in JSON:
        {"connections": [{"from": "concept", "to": "concept", "insight": "why connected"}],
         "patterns": [{"description": "pattern", "importance": 0.0-1.0}],
         "entities": ["key concepts to track"]}
        """

        case call_llm_with_budget(prompt, state, max_tokens: 400) do
          {:ok, response, new_state} ->
            insights = parse_consolidation_insights(response)
            apply_consolidation_insights(insights)
            {%{memories_analyzed: length(memories), insights: insights}, new_state}

          {:error, :budget_exhausted, new_state} ->
            {%{skipped: :budget_exhausted}, new_state}

          {:error, reason, new_state} ->
            {%{error: reason}, new_state}
        end
      else
        {%{skipped: :insufficient_memories}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # Process 2: Emergence Enhancement
  # ============================================================================

  defp execute_process(:emergence_enhancement, state) do
    Logger.debug("[BackgroundCognition] Running emergence enhancement")

    try do
      # Get current patterns using Pattern.list/1
      case Pattern.list(limit: 10, status: :active) do
        patterns when is_list(patterns) and patterns != [] ->
          pattern_summaries =
            patterns
            |> Enum.map_join("\n", fn p ->
              "- #{p.type}: #{p.description} (#{p.occurrences}x, #{Float.round(p.success_rate * 100, 1)}%)"
            end)

          prompt = """
          Review these detected patterns and suggest:
          1. Which patterns should be promoted to high-priority
          2. New pattern categories that might exist but aren't detected
          3. Patterns that should be merged or deprecated

          Current patterns:
          #{pattern_summaries}

          Respond in JSON:
          {"promote": ["pattern_type"], "new_categories": [{"name": "name", "description": "what to detect"}], "deprecate": ["pattern_type"]}
          """

          case call_llm_with_budget(prompt, state, max_tokens: 300) do
            {:ok, response, new_state} ->
              suggestions = parse_emergence_suggestions(response)
              apply_emergence_suggestions(suggestions)
              {%{patterns_reviewed: length(patterns), suggestions: suggestions}, new_state}

            {:error, :budget_exhausted, new_state} ->
              {%{skipped: :budget_exhausted}, new_state}

            {:error, reason, new_state} ->
              {%{error: reason}, new_state}
          end

        _ ->
          {%{skipped: :no_patterns}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # Process 3: Context Pre-computation
  # ============================================================================

  defp execute_process(:context_precomputation, state) do
    Logger.debug("[BackgroundCognition] Running context pre-computation")

    try do
      # Get recent high-importance memories
      memories =
        Memory.search_memories("*", limit: 20)
        |> Enum.filter(fn m -> (m.importance || 0.5) > 0.6 end)

      if length(memories) >= 3 do
        memory_content =
          memories
          |> Enum.take(8)
          |> Enum.map_join("\n", fn m -> "- #{m.content}" end)

        prompt = """
        Based on these important recent memories, prepare a context summary
        for the next session. Include:
        1. Key topics the user is currently working on
        2. Unresolved questions or tasks
        3. Important decisions made
        4. Suggested starting points for next session

        Recent important memories:
        #{memory_content}

        Respond in JSON:
        {"summary": "brief context", "active_topics": ["topic"], "unresolved": ["item"], "suggested_start": "what to do first"}
        """

        case call_llm_with_budget(prompt, state, max_tokens: 400) do
          {:ok, response, new_state} ->
            context = parse_precomputed_context(response)
            store_precomputed_context(context)
            {%{context_prepared: true, topics: context[:active_topics] || []}, new_state}

          {:error, :budget_exhausted, new_state} ->
            {%{skipped: :budget_exhausted}, new_state}

          {:error, reason, new_state} ->
            {%{error: reason}, new_state}
        end
      else
        {%{skipped: :insufficient_important_memories}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # Process 4: Decay Intelligence
  # ============================================================================
  # DISABLED: This process is dangerous without safety mitigations.
  # Issues identified:
  # - Setting importance to 0.0 triggers permanent deletion via Forgetting cycle
  # - No undo mechanism, no audit log
  # - LLM could be prompt-injected via memory content
  # - No check for graph edge references before deletion
  #
  # TODO: Re-enable after implementing:
  # 1. Soft delete with recovery period
  # 2. Audit log for all decay decisions
  # 3. Graph edge reference check
  # 4. Minimum importance of 0.1 (not 0.0)

  defp execute_process(:decay_intelligence, state) do
    Logger.debug("[BackgroundCognition] Decay intelligence DISABLED for safety")
    {%{skipped: :disabled_for_safety, reason: "Needs safety mitigations before use"}, state}
  end

  # Original implementation preserved for reference:
  # defp execute_process_decay_intelligence_DISABLED(state) do
  #   try do
  #     # Get memories at risk of decay using DecayScorer
  #     at_risk = get_at_risk_memories(limit: 20)
  #
  #     if length(at_risk) >= 5 do
  #       memory_list = at_risk
  #         |> Enum.take(10)
  #         |> Enum.map_join("\n", fn m ->
  #           "- [#{m.category}] #{m.content} (importance: #{m.importance}, accesses: #{m.access_count})"
  #         end)
  #
  #       prompt = """
  #       Review these memories that are candidates for decay/deletion.
  #       For each, decide: KEEP (increase importance), ARCHIVE (keep but reduce priority), or FORGET.
  #       ...
  #       """
  #       # ... rest of implementation
  #     end
  #   end
  # end

  # ============================================================================
  # Process 5: Knowledge Synthesis (runs once per day max)
  # ============================================================================

  defp execute_process(:knowledge_synthesis, state) do
    # Check if 24 hours have passed since last synthesis
    if synthesis_too_recent?(state) do
      Logger.debug("[BackgroundCognition] Knowledge synthesis skipped (daily limit)")
      {%{skipped: :daily_limit, next_eligible_in: time_until_next_synthesis(state)}, state}
    else
      do_knowledge_synthesis(state)
    end
  end

  # ============================================================================
  # Process 6: Knowledge Promotion (Knowledge Ladder Pipeline)
  # ============================================================================
  # This is the KEY process that connects the knowledge ladder:
  # Observations → Facts → Triples → Procedures
  #
  # It takes patterns that are ready for promotion and:
  # 1. :inference patterns → SemanticStore triples
  # 2. :workflow patterns → Procedural memory
  # 3. :skill patterns → High-importance fact memories

  defp execute_process(:knowledge_promotion, state) do
    Logger.debug("[BackgroundCognition] Running knowledge promotion pipeline")

    try do
      # Get patterns ready for promotion
      candidates =
        Pattern.promotion_candidates(
          min_occurrences: 5,
          min_success_rate: 0.7,
          min_strength: 0.6
        )

      if candidates != [] do
        results =
          Enum.map(candidates, fn pattern ->
            promote_pattern_to_knowledge(pattern)
          end)

        successful = Enum.count(results, fn {status, _} -> status == :ok end)

        :telemetry.execute(
          [:mimo, :background_cognition, :knowledge_promotion],
          %{patterns_promoted: successful, patterns_attempted: length(candidates)},
          %{source: :background_cognition}
        )

        {%{
           candidates_found: length(candidates),
           patterns_promoted: successful,
           results: Enum.take(results, 5)
         }, state}
      else
        {%{skipped: :no_candidates, reason: "No patterns ready for promotion"}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # Process 7: Upgrade Analysis (PAI-inspired self-improvement)
  # ============================================================================

  defp execute_process(:upgrade_analysis, state) do
    Logger.debug("[BackgroundCognition] Running upgrade analysis")

    try do
      case UpgradeSkill.analyze_and_recommend(days: 14, limit: 3) do
        {:ok, recommendations} when recommendations != [] ->
          # Store recommendations for later retrieval
          UpgradeSkill.store_recommendations(recommendations)

          :telemetry.execute(
            [:mimo, :background_cognition, :upgrade_analysis],
            %{recommendations_generated: length(recommendations)},
            %{source: :background_cognition}
          )

          {%{
             recommendations_count: length(recommendations),
             recommendations:
               Enum.map(recommendations, fn r ->
                 %{type: r.type, priority: r.priority, title: r.title}
               end)
           }, state}

        {:ok, []} ->
          {%{skipped: :no_recommendations, reason: "System is performing well"}, state}

        {:error, reason} ->
          {%{error: inspect(reason)}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # Knowledge Promotion Helpers
  # ============================================================================

  defp promote_pattern_to_knowledge(pattern) do
    case pattern.type do
      :inference ->
        # Convert inference patterns to semantic triples
        promote_inference_to_triple(pattern)

      :workflow ->
        # Promote via existing Promoter (creates procedure)
        Promoter.promote(pattern)

      :skill ->
        # Store as high-importance procedural memory
        promote_skill_to_memory(pattern)

      :heuristic ->
        # Store as fact memory with the heuristic
        promote_heuristic_to_memory(pattern)
    end
  end

  defp promote_inference_to_triple(pattern) do
    # Check if SemanticStore is enabled
    if Mimo.Application.feature_enabled?(:semantic_store) do
      # Extract relationships from the pattern description
      text = """
      #{pattern.description}
      Components: #{Enum.join(pattern.components || [], ", ")}
      """

      case Ingestor.ingest_text(text, "emergence:#{pattern.id}") do
        {:ok, count} ->
          # Mark pattern as promoted
          Pattern.promote(pattern)
          {:ok, %{type: :inference, triples_created: count}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.debug("[BackgroundCognition] SemanticStore disabled, skipping inference promotion")
      {:ok, %{type: :inference, skipped: :feature_disabled}}
    end
  end

  defp promote_skill_to_memory(pattern) do
    content = """
    [Promoted Skill: #{pattern.type}]
    #{pattern.description}

    Trigger conditions: #{Enum.join(pattern.trigger_conditions || [], ", ")}
    Success rate: #{Float.round((pattern.success_rate || 0) * 100, 1)}%
    Occurrences: #{pattern.occurrences}
    """

    case Memory.persist_memory(content, "fact", 0.85,
           tags: ["promoted_skill", "emergence", "pattern:#{pattern.id}"]
         ) do
      {:ok, _} ->
        Pattern.promote(pattern)
        {:ok, %{type: :skill, memory_created: true}}

      error ->
        error
    end
  end

  defp promote_heuristic_to_memory(pattern) do
    content = """
    [Promoted Heuristic]
    #{pattern.description}

    When to apply: #{Enum.join(pattern.trigger_conditions || [], ", ")}
    Reliability: #{Float.round((pattern.success_rate || 0) * 100, 1)}%
    """

    case Memory.persist_memory(content, "fact", 0.8,
           tags: ["promoted_heuristic", "emergence", "pattern:#{pattern.id}"]
         ) do
      {:ok, _} ->
        Pattern.promote(pattern)
        {:ok, %{type: :heuristic, memory_created: true}}

      error ->
        error
    end
  end

  # ============================================================================
  # Knowledge Synthesis Helpers
  # ============================================================================

  defp synthesis_too_recent?(state) do
    case state.last_synthesis_at do
      nil ->
        false

      last_time ->
        elapsed = DateTime.diff(DateTime.utc_now(), last_time, :millisecond)
        elapsed < @synthesis_interval_ms
    end
  end

  defp time_until_next_synthesis(state) do
    case state.last_synthesis_at do
      nil ->
        0

      last_time ->
        elapsed = DateTime.diff(DateTime.utc_now(), last_time, :millisecond)
        max(0, @synthesis_interval_ms - elapsed)
    end
  end

  defp do_knowledge_synthesis(state) do
    Logger.debug("[BackgroundCognition] Running knowledge synthesis")

    try do
      # Get diverse memories for synthesis
      fact_memories = Memory.search_memories("*", limit: 10, category: "fact")
      action_memories = Memory.search_memories("*", limit: 10, category: "action")

      all_memories = (fact_memories ++ action_memories) |> Enum.uniq_by(& &1.id) |> Enum.take(15)

      if length(all_memories) >= 5 do
        memory_content =
          all_memories
          |> Enum.map_join("\n", fn m -> "- [#{m.category}] #{m.content}" end)

        prompt = """
        Synthesize these diverse memories into higher-level insights.
        Look for:
        1. Meta-patterns (patterns about patterns)
        2. Cross-domain connections
        3. Emerging principles or rules

        Memories:
        #{memory_content}

        Respond in JSON:
        {"syntheses": [{"insight": "the insight", "based_on": ["memory snippets"], "importance": 0.0-1.0}]}
        """

        case call_llm_with_budget(prompt, state, max_tokens: 400) do
          {:ok, response, new_state} ->
            syntheses = parse_syntheses(response)
            store_syntheses(syntheses)
            # Update last_synthesis_at on success
            updated_state = %{new_state | last_synthesis_at: DateTime.utc_now()}

            {%{memories_synthesized: length(all_memories), insights: length(syntheses)},
             updated_state}

          {:error, :budget_exhausted, new_state} ->
            {%{skipped: :budget_exhausted}, new_state}

          {:error, reason, new_state} ->
            {%{error: reason}, new_state}
        end
      else
        {%{skipped: :insufficient_memories}, state}
      end
    rescue
      e -> {%{error: Exception.message(e)}, state}
    end
  end

  # ============================================================================
  # LLM Call Management
  # ============================================================================

  defp call_llm_with_budget(prompt, state, opts) do
    if state.llm_calls_this_cycle >= @max_llm_calls_per_cycle do
      {:error, :budget_exhausted, state}
    else
      # Rate limit: wait if needed
      Process.sleep(@llm_call_interval_ms)

      case LLM.complete(prompt, opts ++ [format: :json, raw: true, timeout: 30_000]) do
        {:ok, response} ->
          new_state = %{state | llm_calls_this_cycle: state.llm_calls_this_cycle + 1}
          {:ok, response, new_state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  # ============================================================================
  # Parsing Helpers
  # ============================================================================

  defp parse_consolidation_insights(response) do
    case parse_json(response) do
      {:ok, %{"connections" => connections, "patterns" => patterns, "entities" => entities}} ->
        %{connections: connections || [], patterns: patterns || [], entities: entities || []}

      _ ->
        %{connections: [], patterns: [], entities: []}
    end
  end

  defp parse_emergence_suggestions(response) do
    case parse_json(response) do
      {:ok, data} -> data
      _ -> %{}
    end
  end

  defp parse_precomputed_context(response) do
    case parse_json(response) do
      {:ok, data} -> data
      _ -> %{}
    end
  end

  defp parse_syntheses(response) do
    case parse_json(response) do
      {:ok, %{"syntheses" => syntheses}} when is_list(syntheses) -> syntheses
      _ -> []
    end
  end

  defp parse_json(response) do
    # Try to extract JSON from response
    json_match = Regex.run(~r/\{[\s\S]*\}/, response)

    case json_match do
      [json_str] -> Jason.decode(json_str)
      _ -> {:error, :no_json}
    end
  end

  # ============================================================================
  # Application Helpers
  # ============================================================================

  defp apply_consolidation_insights(%{connections: connections, entities: entities}) do
    # Create graph edges for connections
    Enum.each(connections, fn conn ->
      try do
        with {:ok, from_node} <- Graph.find_or_create_node(:concept, conn["from"]),
             {:ok, to_node} <- Graph.find_or_create_node(:concept, conn["to"]) do
          Graph.create_edge(%{
            source_node_id: from_node.id,
            target_node_id: to_node.id,
            edge_type: :deep_connection,
            properties: %{insight: conn["insight"], source: "background_cognition"}
          })

          # KNOWLEDGE LADDER: Also create semantic triple for the connection (if enabled)
          if Mimo.Application.feature_enabled?(:semantic_store) do
            triple = %{
              subject: conn["from"],
              predicate: "relates_to",
              object: conn["to"]
            }

            Ingestor.ingest_triple(triple, "background_cognition:consolidation")
          end
        end
      rescue
        _ -> :ok
      end
    end)

    # Create entity nodes
    Enum.each(entities, fn entity ->
      try do
        Graph.find_or_create_node(:concept, entity, %{source: "background_cognition"})
      rescue
        _ -> :ok
      end
    end)

    # KNOWLEDGE LADDER: Emit telemetry for tracking
    :telemetry.execute(
      [:mimo, :background_cognition, :consolidation_to_triples],
      %{connections_processed: length(connections), entities_processed: length(entities)},
      %{source: :background_cognition}
    )
  end

  defp apply_emergence_suggestions(suggestions) do
    # Log for now - actual promotion would need Emergence module changes
    if Map.has_key?(suggestions, "promote") do
      Logger.info("[BackgroundCognition] Suggesting promotion: #{inspect(suggestions["promote"])}")
    end
  end

  defp store_precomputed_context(context) do
    # Store as a high-importance memory for next session pickup
    content = """
    [Pre-computed Session Context]
    Summary: #{context["summary"] || "No summary"}
    Active Topics: #{inspect(context["active_topics"] || [])}
    Unresolved: #{inspect(context["unresolved"] || [])}
    Suggested Start: #{context["suggested_start"] || "No suggestion"}
    """

    Memory.persist_memory(content, "plan", 0.9, tags: ["precomputed_context", "session_start"])
  rescue
    _ -> :ok
  end

  # NOTE: Decay intelligence functions removed - the feature is disabled for safety.
  # See execute_process(:decay_intelligence, state) for details.

  # Quality gates for synthesized insights (Phase 2: Data Quality Excellence)
  @min_synthesis_insight_length 100
  @min_synthesis_importance 0.6

  defp store_syntheses(syntheses) do
    # Filter out low-quality syntheses before storing
    quality_syntheses =
      Enum.filter(syntheses, fn synthesis ->
        insight = synthesis["insight"] || ""
        importance = synthesis["importance"] || 0.0

        passes_quality =
          String.length(insight) >= @min_synthesis_insight_length and
            importance >= @min_synthesis_importance

        unless passes_quality do
          Logger.debug(
            "[BackgroundCognition] Rejected low-quality synthesis: #{String.slice(insight, 0, 50)}... (len=#{String.length(insight)}, imp=#{importance})"
          )
        end

        passes_quality
      end)

    Logger.info(
      "[BackgroundCognition] Quality filter: #{length(quality_syntheses)}/#{length(syntheses)} syntheses passed"
    )

    triples_created =
      Enum.reduce(quality_syntheses, 0, fn synthesis, acc ->
        importance = synthesis["importance"] || 0.7

        content = """
        [Synthesized Insight]
        #{synthesis["insight"]}
        Based on: #{inspect(synthesis["based_on"] || [])}
        """

        # DEDUP FIX: Check if this synthesis already exists before storing
        # Uses direct SQL query to avoid HNSW index desync issues
        already_exists =
          case Mimo.Repo.query(
                 "SELECT 1 FROM engrams WHERE content LIKE ? LIMIT 1",
                 ["%[Synthesized Insight]%#{synthesis["insight"] |> String.slice(0, 50)}%"]
               ) do
            {:ok, %{num_rows: n}} when n > 0 -> true
            _ -> false
          end

        unless already_exists do
          Memory.persist_memory(content, "fact", importance,
            tags: ["synthesis", "background_cognition"]
          )
        end

        # KNOWLEDGE LADDER: Also extract triples from the synthesis insight (if enabled)
        if Mimo.Application.feature_enabled?(:semantic_store) do
          case Ingestor.ingest_text(
                 synthesis["insight"] || "",
                 "background_cognition:synthesis"
               ) do
            {:ok, count} -> acc + count
            _ -> acc
          end
        else
          acc
        end
      end)

    # Emit telemetry for the knowledge ladder
    :telemetry.execute(
      [:mimo, :background_cognition, :synthesis_to_triples],
      %{
        syntheses_processed: length(quality_syntheses),
        syntheses_filtered: length(syntheses) - length(quality_syntheses),
        triples_created: triples_created
      },
      %{source: :background_cognition}
    )
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  defp session_ended?(state) do
    time_since_activity(state) > @session_ended_threshold_ms
  end

  defp time_since_activity(state) do
    System.monotonic_time(:millisecond) - state.last_activity
  end

  defp should_run_cycle?(state) do
    case state.last_cycle_at do
      nil ->
        true

      last_time ->
        # Don't run more than once per hour
        time_since = DateTime.diff(DateTime.utc_now(), last_time, :millisecond)
        time_since > 60 * 60 * 1000
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, @idle_check_interval_ms)
  end

  defp update_stats(stats, results, llm_calls) do
    %{
      stats
      | cycles_completed: stats.cycles_completed + 1,
        llm_calls_total: stats.llm_calls_total + llm_calls,
        deep_consolidations:
          stats.deep_consolidations + if(results[:deep_consolidation][:insights], do: 1, else: 0),
        patterns_enhanced:
          stats.patterns_enhanced +
            if(results[:emergence_enhancement][:suggestions], do: 1, else: 0),
        contexts_precomputed:
          stats.contexts_precomputed +
            if(results[:context_precomputation][:context_prepared], do: 1, else: 0),
        decay_decisions: stats.decay_decisions + (results[:decay_intelligence][:decisions] || 0),
        syntheses_created:
          stats.syntheses_created + (results[:knowledge_synthesis][:insights] || 0),
        patterns_promoted:
          stats.patterns_promoted + (results[:knowledge_promotion][:patterns_promoted] || 0),
        upgrade_recommendations:
          stats.upgrade_recommendations + (results[:upgrade_analysis][:recommendations_count] || 0)
    }
  rescue
    _ -> stats
  end

  # ============================================================================
  # PRESERVED FUNCTIONS - For future decay_intelligence re-enablement
  # These are intentionally kept for when the decay intelligence feature is
  # reactivated. Uncomment when ready to use.
  # ============================================================================

  # Commented out to avoid compiler warnings - these are preserved for future use
  # defp _parse_decay_decisions(decisions_json) when is_binary(decisions_json) do
  #   case Jason.decode(decisions_json) do
  #     {:ok, decisions} when is_list(decisions) -> decisions
  #     _ -> []
  #   end
  # end
  #
  # defp _parse_decay_decisions(_), do: []
  #
  # defp _get_at_risk_memories(opts) do
  #   limit = Keyword.get(opts, :limit, 20)
  #
  #   # Get memories and filter by decay score using DecayScorer
  #   try do
  #     memories = Memory.search_memories("*", limit: 100)
  #
  #     memories
  #     |> Enum.map(fn m -> {m, DecayScorer.calculate_score(m)} end)
  #     |> Enum.filter(fn {_m, score} -> score < 0.5 end)  # Low score = at risk
  #     |> Enum.sort_by(fn {_m, score} -> score end, :asc)  # Most at-risk first
  #     |> Enum.take(limit)
  #     |> Enum.map(fn {m, _score} -> m end)
  #   rescue
  #     _ -> []
  #   end
  # end
  #
  # defp _apply_decay_decisions(memories, decisions) do
  #   Enum.each(decisions, fn decision ->
  #     index = decision["index"]
  #     action = decision["action"]
  #
  #     if index && index < length(memories) do
  #       memory = Enum.at(memories, index)
  #
  #       case action do
  #         "KEEP" ->
  #           # Boost importance
  #           Memory.update_importance(memory.id, min(1.0, (memory.importance || 0.5) + 0.2))
  #
  #         "FORGET" ->
  #           # Mark for forgetting by setting importance to 0
  #           # The Forgetting cycle will clean it up
  #           Memory.update_importance(memory.id, 0.0)
  #
  #         "ARCHIVE" ->
  #           # Reduce importance but keep
  #           Memory.update_importance(memory.id, max(0.1, (memory.importance || 0.5) - 0.1))
  #
  #         _ ->
  #           :ok
  #       end
  #     end
  #   end)
  # rescue
  #   _ -> :ok
  # end
end
