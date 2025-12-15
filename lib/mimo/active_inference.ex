defmodule Mimo.ActiveInference do
  @moduledoc """
  SPEC-071: Active Inference Loop - Proactive Context Pushing.

  Based on the Free Energy Principle: minimizes "surprise" by anticipating
  what context the user will need and pushing it proactively.

  ## Architecture

  The Active Inference loop runs in 3 phases:

  1. **PREDICT**: Analyze current query/action to predict future needs
     - Task type detection (coding, debugging, architecture, etc.)
     - Access pattern analysis (what resources are typically needed together)
     - Temporal patterns (what comes next in typical workflows)

  2. **PREFETCH**: Asynchronously gather predicted context
     - Memory search for relevant past experiences
     - Knowledge graph traversal for related concepts
     - Code symbol lookup for likely dependencies

  3. **PUSH**: Inject context into response before user asks
     - Proactive suggestions in response
     - Pre-populated context in tool results
     - Anticipatory warnings about common pitfalls

  ## Free Energy Minimization

  The system tracks "surprise" (unexpected user requests) and adjusts predictions
  to minimize it over time. High surprise → update prediction model.

  ## References

  - CoALA Framework: Cognitive Architectures for Language Agents
  - Active Inference: The Free Energy Principle in Action
  - SPEC-065: Pre-Tool Injection (precursor)
  - SPEC-070: Meta-Cognitive Router (classification)
  """

  use GenServer
  require Logger

  alias Mimo.Context.AccessPatternTracker
  alias Mimo.Brain.{Memory, MemoryRouter}
  alias Mimo.Synapse.Graph
  alias Mimo.MetaCognitiveRouter
  alias Mimo.Cognitive.FeedbackLoop

  # Configuration
  @prediction_timeout_ms 100
  @prefetch_timeout_ms 500
  @max_prefetch_items 5
  @surprise_decay 0.9
  @surprise_threshold 0.7

  # State
  defstruct [
    :predictions_cache,
    :prefetch_cache,
    :surprise_scores,
    :stats,
    # NEW: Learned adjustments from feedback
    :learned_weights
  ]

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run the active inference loop for a query.

  Returns predicted context that should be proactively pushed to the user.

  ## Parameters
    - `query` - The current user query
    - `opts` - Options:
      - `:context` - Additional context (tool name, file path, etc.)
      - `:session_id` - Session identifier for pattern tracking
      - `:timeout` - Custom timeout in ms

  ## Returns
    - `{:ok, inference}` - Map with predictions and prefetched context
    - `{:error, reason}` - If inference fails (returns empty context)
  """
  @spec infer(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def infer(query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @prefetch_timeout_ms + @prediction_timeout_ms)

    try do
      GenServer.call(__MODULE__, {:infer, query, opts}, timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.debug("[ActiveInference] Inference timed out, returning empty context")
        {:ok, empty_inference()}

      :exit, _ ->
        {:ok, empty_inference()}
    end
  end

  @doc """
  Record whether predicted context was actually used.

  This feedback loop improves predictions over time by tracking "surprise"
  (predictions that weren't used = low value, unexpected requests = high surprise).
  """
  @spec record_outcome(String.t(), map()) :: :ok
  def record_outcome(query, outcome) do
    GenServer.cast(__MODULE__, {:record_outcome, query, outcome})
  end

  @doc """
  Get current inference statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      predictions_cache: %{},
      prefetch_cache: %{},
      surprise_scores: %{},
      stats: %{
        inferences: 0,
        cache_hits: 0,
        predictions_used: 0,
        avg_latency_ms: 0.0
      },
      learned_weights: load_learned_weights()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:infer, query, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    tracking_id = generate_tracking_id()

    # Phase 1: PREDICT - What context will be needed?
    # NOW USES LEARNED WEIGHTS from feedback!
    predictions = predict_context_needs(query, opts, state.learned_weights)

    # Phase 2: PREFETCH - Gather predicted context in parallel
    prefetched = prefetch_context(predictions, opts)

    # Phase 3: Assemble inference result
    inference = %{
      # NEW: For feedback correlation
      tracking_id: tracking_id,
      query_type: predictions.task_type,
      predicted_needs: predictions.needs,
      prefetched_context: prefetched,
      confidence: predictions.confidence,
      suggestions: generate_suggestions(predictions, prefetched),
      source: "active_inference"
    }

    # Record prediction in FeedbackLoop for later outcome tracking
    FeedbackLoop.record_outcome(
      :prediction,
      %{
        query: query,
        tracking_id: tracking_id,
        predicted_needs: predictions.needs,
        task_type: predictions.task_type,
        confidence: predictions.confidence
      },
      %{success: true, latency_ms: System.monotonic_time(:millisecond) - start_time, used: []}
    )

    # Update stats
    latency = System.monotonic_time(:millisecond) - start_time
    new_stats = update_stats(state.stats, latency)

    emit_telemetry(latency, predictions.task_type)

    {:reply, {:ok, inference}, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:record_outcome, query, outcome}, state) do
    # Calculate surprise score
    surprise = calculate_surprise(outcome)

    # Update surprise scores with decay
    new_scores =
      state.surprise_scores
      |> Map.update(hash_query(query), surprise, fn old ->
        @surprise_decay * old + (1 - @surprise_decay) * surprise
      end)

    # Log if surprise is high (we're not predicting well)
    if surprise > @surprise_threshold do
      Logger.info(
        "[ActiveInference] High surprise (#{Float.round(surprise, 2)}) - updating predictions"
      )
    end

    # NEW: Update learned weights based on outcome feedback
    new_weights = update_learned_weights(state.learned_weights, outcome)

    # NEW: Record detailed feedback for cross-system learning
    record_detailed_feedback(query, outcome, surprise)

    {:noreply, %{state | surprise_scores: new_scores, learned_weights: new_weights}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ==========================================================================
  # Phase 1: PREDICT
  # ==========================================================================

  defp predict_context_needs(query, opts, learned_weights) do
    # Get task type from router classification
    classification = MetaCognitiveRouter.classify(query)

    # Get task-specific predictions from pattern tracker
    pattern_predictions =
      try do
        AccessPatternTracker.predict(query)
      rescue
        _ -> %{}
      end

    # Extract context hints from opts
    context = Keyword.get(opts, :context, %{})

    # Determine predicted needs - NOW WITH LEARNED ADJUSTMENTS
    needs = determine_needs(classification, pattern_predictions, context, learned_weights)

    %{
      task_type: classification.primary_store,
      classification: classification,
      pattern_predictions: pattern_predictions,
      needs: needs,
      confidence: classification.confidence
    }
  end

  defp determine_needs(classification, pattern_predictions, context, learned_weights) do
    base_needs =
      case classification.primary_store do
        :procedural ->
          # Code tasks need: related functions, past errors, dependencies
          [:related_code, :past_errors, :dependencies]

        :semantic ->
          # Architecture tasks need: relationships, structure, concepts
          [:relationships, :concepts, :architecture_docs]

        :episodic ->
          # Experience tasks need: past conversations, decisions, outcomes
          [:past_conversations, :decisions, :similar_experiences]

        _ ->
          [:general_context]
      end

    # Add pattern-based predictions
    pattern_needs =
      pattern_predictions
      |> Map.get(:likely_resources, [])
      |> Enum.take(3)

    # Add context-specific needs
    context_needs =
      cond do
        Map.has_key?(context, :file) -> [:file_history, :related_files]
        Map.has_key?(context, :error) -> [:similar_errors, :fixes]
        true -> []
      end

    all_needs = Enum.uniq(base_needs ++ pattern_needs ++ context_needs)

    # NEW: Apply learned weights to prioritize needs
    apply_learned_weights(all_needs, learned_weights)
  end

  # NEW: Sort and filter needs based on learned success rates
  defp apply_learned_weights(needs, learned_weights) do
    needs
    |> Enum.map(fn need ->
      weight = Map.get(learned_weights, need, 0.5)
      {need, weight}
    end)
    |> Enum.sort_by(fn {_, weight} -> weight end, :desc)
    # Filter out consistently unused predictions
    |> Enum.filter(fn {_, weight} -> weight > 0.2 end)
    |> Enum.map(fn {need, _} -> need end)
  end

  # ==========================================================================
  # Phase 2: PREFETCH
  # ==========================================================================

  defp prefetch_context(predictions, _opts) do
    # Launch parallel prefetch tasks
    tasks =
      predictions.needs
      |> Enum.take(@max_prefetch_items)
      |> Enum.map(fn need ->
        Task.async(fn -> prefetch_single(need, predictions) end)
      end)

    # Await with timeout
    results =
      tasks
      |> Task.yield_many(@prefetch_timeout_ms)
      |> Enum.map(fn
        {_task, {:ok, result}} ->
          result

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    results
  end

  defp prefetch_single(:related_code, predictions) do
    # Search for related code symbols based on classification
    query = predictions.classification.reasoning

    case Mimo.Code.SymbolIndex.search(query, limit: 3) do
      {:ok, symbols} -> {:related_code, symbols}
      _ -> {:related_code, []}
    end
  rescue
    _ -> {:related_code, []}
  end

  defp prefetch_single(:past_errors, _predictions) do
    # Search for past error memories
    case Memory.search_memories("error OR bug OR fix", limit: 3, category: "observation") do
      results when is_list(results) ->
        {:past_errors, Enum.map(results, & &1.content)}

      _ ->
        {:past_errors, []}
    end
  rescue
    _ -> {:past_errors, []}
  end

  defp prefetch_single(:dependencies, predictions) do
    # Look up dependencies in knowledge graph
    query = predictions.classification.reasoning

    case Graph.search_nodes(query, types: [:module, :external_lib], limit: 5) do
      nodes when is_list(nodes) ->
        {:dependencies, Enum.map(nodes, & &1.name)}

      _ ->
        {:dependencies, []}
    end
  rescue
    _ -> {:dependencies, []}
  end

  defp prefetch_single(:relationships, predictions) do
    # Get relationship suggestions from Observer
    entities = extract_entities(predictions.classification.reasoning)

    case Mimo.SemanticStore.Observer.observe(entities) do
      {:ok, suggestions} ->
        {:relationships, suggestions}

      _ ->
        {:relationships, []}
    end
  rescue
    _ -> {:relationships, []}
  end

  defp prefetch_single(:past_conversations, _predictions) do
    # Get recent ask_mimo conversations
    case Memory.search_memories("AI asked Mimo", limit: 3, category: "observation") do
      results when is_list(results) ->
        {:past_conversations, Enum.map(results, & &1.content)}

      _ ->
        {:past_conversations, []}
    end
  rescue
    _ -> {:past_conversations, []}
  end

  defp prefetch_single(:similar_experiences, predictions) do
    # Vector search for similar past experiences
    query = predictions.classification.reasoning

    case MemoryRouter.route(query, limit: 3) do
      {:ok, results} ->
        memories =
          Enum.map(results, fn
            {mem, _score} -> mem.content
            mem -> mem.content
          end)

        {:similar_experiences, memories}

      _ ->
        {:similar_experiences, []}
    end
  rescue
    _ -> {:similar_experiences, []}
  end

  defp prefetch_single(_need, _predictions) do
    # Default: no prefetch for unknown need types
    nil
  end

  # ==========================================================================
  # Phase 3: Generate Suggestions
  # ==========================================================================

  defp generate_suggestions(predictions, prefetched) do
    suggestions = []

    # Add error-related suggestions if we found past errors
    suggestions =
      case Map.get(prefetched, :past_errors, []) do
        [_error | _] = errors when errors != [] ->
          suggestion = "💡 Similar past issue: #{String.slice(List.first(errors), 0, 100)}..."
          [suggestion | suggestions]

        _ ->
          suggestions
      end

    # Add relationship suggestions
    suggestions =
      case Map.get(prefetched, :relationships, []) do
        [rel | _] when is_map(rel) ->
          suggestion = "🔗 Related: #{rel[:text] || inspect(rel)}"
          [suggestion | suggestions]

        _ ->
          suggestions
      end

    # Add dependency suggestions for code tasks
    suggestions =
      if predictions.task_type == :procedural do
        case Map.get(prefetched, :dependencies, []) do
          [_dep | _] = deps when deps != [] ->
            suggestion = "📦 May need: #{Enum.join(Enum.take(deps, 3), ", ")}"
            [suggestion | suggestions]

          _ ->
            suggestions
        end
      else
        suggestions
      end

    Enum.take(suggestions, 3)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp empty_inference do
    %{
      query_type: :unknown,
      predicted_needs: [],
      prefetched_context: %{},
      confidence: 0.0,
      suggestions: [],
      source: "active_inference_fallback"
    }
  end

  defp calculate_surprise(outcome) do
    predictions_used = Map.get(outcome, :predictions_used, 0)
    total_predictions = Map.get(outcome, :total_predictions, 1)
    unexpected_requests = Map.get(outcome, :unexpected_requests, 0)

    # Low usage + high unexpected = high surprise
    usage_rate = if total_predictions > 0, do: predictions_used / total_predictions, else: 0
    surprise = (1 - usage_rate) * 0.5 + min(unexpected_requests * 0.25, 0.5)

    min(surprise, 1.0)
  end

  defp hash_query(query) do
    :crypto.hash(:md5, query) |> Base.encode16(case: :lower) |> String.slice(0, 8)
  end

  defp update_stats(stats, latency) do
    n = stats.inferences + 1
    new_avg = (stats.avg_latency_ms * stats.inferences + latency) / n

    %{stats | inferences: n, avg_latency_ms: Float.round(new_avg, 2)}
  end

  defp emit_telemetry(latency, task_type) do
    :telemetry.execute(
      [:mimo, :active_inference, :infer],
      %{latency_ms: latency},
      %{task_type: task_type}
    )
  end

  defp extract_entities(text) do
    # Extract potential entity names from text
    Regex.scan(~r/\b([A-Z][a-z]+(?:[A-Z][a-z]+)*)\b/, text || "")
    |> Enum.map(fn [_, match] -> match end)
    |> Enum.take(5)
  end

  # ==========================================================================
  # Learning Functions (NEW for SPEC-074 Integration)
  # ==========================================================================

  defp generate_tracking_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc false
  # Load learned weights from FeedbackLoop or initialize defaults
  defp load_learned_weights do
    try do
      # Query feedback statistics to initialize weights
      case FeedbackLoop.query_patterns(:prediction) do
        %{by_type: type_stats} when is_map(type_stats) and map_size(type_stats) > 0 ->
          type_stats

        _ ->
          default_weights()
      end
    rescue
      _ -> default_weights()
    end
  end

  defp default_weights do
    # Initial weights for each prediction type (0.5 = neutral)
    %{
      related_code: 0.6,
      past_errors: 0.5,
      dependencies: 0.5,
      relationships: 0.5,
      concepts: 0.4,
      architecture_docs: 0.4,
      past_conversations: 0.5,
      decisions: 0.4,
      similar_experiences: 0.6,
      general_context: 0.3,
      file_history: 0.5,
      related_files: 0.5,
      similar_errors: 0.6,
      fixes: 0.6
    }
  end

  @doc false
  # Update weights based on what was actually used
  defp update_learned_weights(weights, outcome) do
    predicted = Map.get(outcome, :predicted, [])
    used = Map.get(outcome, :used, [])

    # Increase weight for used predictions, decrease for unused
    Enum.reduce(predicted, weights, fn pred, acc ->
      current = Map.get(acc, pred, 0.5)

      new_weight =
        if pred in used do
          # Used: increase weight (bounded at 0.95)
          min(current + 0.05, 0.95)
        else
          # Not used: decrease weight (bounded at 0.1)
          max(current - 0.02, 0.1)
        end

      Map.put(acc, pred, new_weight)
    end)
  end

  @doc false
  # Record detailed feedback for cross-system learning
  defp record_detailed_feedback(query, outcome, surprise) do
    predicted = Map.get(outcome, :predicted, [])
    used = Map.get(outcome, :used, [])

    # Record to FeedbackLoop with full context
    FeedbackLoop.record_outcome(
      :prediction,
      %{
        query: query,
        predicted_needs: predicted,
        surprise_score: surprise
      },
      %{
        success: surprise < @surprise_threshold,
        used: used,
        hit_rate: safe_hit_rate(predicted, used)
      }
    )
  end

  defp safe_hit_rate([], _used), do: 0.0

  defp safe_hit_rate(predicted, used) do
    hits = Enum.count(predicted, &(&1 in used))
    hits / length(predicted)
  end
end
