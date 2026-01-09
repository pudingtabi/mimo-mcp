defmodule Mimo.MetaCognitiveRouter do
  @moduledoc """
  Meta-Cognitive Router: Intelligent query classification layer.

  Routes natural language inputs to the appropriate store:
  - Episodic Store (vector): Narrative, experiential queries
  - Semantic Store (graph): Logic, relationship queries
  - Procedural Store (rules): Code, procedure queries

  SPEC-053: Also provides workflow prediction and suggestion.
  SPEC-070: Embedding-based semantic classification with prototype queries.

  Ref: Universal Aperture TDD - preserves the routing layer while enabling multi-protocol access.
  Ref: CoALA Framework - Adaptive retrieval strategy selection.
  """
  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Cache.Embedding, as: EmbeddingCache
  alias Mimo.Cognitive.FeedbackLoop
  alias Mimo.Vector.Math, as: VectorMath
  alias Mimo.Workflow.{Pattern, Predictor}

  @type store :: :episodic | :semantic | :procedural
  @type decision :: %{
          primary_store: store(),
          secondary_stores: [store()],
          confidence: float(),
          reasoning: String.t(),
          requires_synthesis: boolean()
        }

  @type workflow_suggestion :: %{
          type: :auto_execute | :suggest | :manual,
          pattern: Pattern.t() | nil,
          patterns: [Pattern.t()],
          confidence: float(),
          bindings: map(),
          reason: String.t() | nil
        }

  # Keyword patterns for classification (legacy, still used for blending)
  @procedural_keywords ~w(code bug fix function method class implement compile error syntax)
  @semantic_keywords ~w(relationship between depends structure architecture graph linked)
  @episodic_keywords ~w(remember when before earlier previously history past experience)
  # These represent canonical examples of each query category.
  # Embeddings are computed lazily and cached for fast similarity lookup.

  @prototype_queries %{
    semantic: [
      "What modules depend on this?",
      "How does X relate to Y?",
      "What is the architecture of this system?",
      "Show me the relationships between components",
      "What calls this function?"
    ],
    episodic: [
      "What did we discuss yesterday?",
      "Remember that bug we fixed last week?",
      "What was the error message I saw before?",
      "When did we last change this file?",
      "What happened in our previous session?"
    ],
    procedural: [
      "Fix the undefined function error",
      "Implement the authentication flow",
      "Run the tests and fix failures",
      "How do I configure this library?",
      "Debug the null pointer exception"
    ]
  }

  # Blending weights: embedding similarity vs keyword matching
  @embedding_weight 0.6
  @keyword_weight 0.4

  # SPEC-070: Feedback-based learning weight (Phase 3 Learning Loop)
  # This weight controls how much historical success rates influence routing
  # Start conservative at 0.2 to avoid runaway effects
  @feedback_boost_weight 0.2

  # Minimum sample size before applying feedback boost
  @min_feedback_samples 10

  # ETS table for cached prototype embeddings
  @prototype_cache :mimo_router_prototypes

  @doc """
  Classify a query and determine routing to Triad Stores.

  ## Examples

      iex> Mimo.MetaCognitiveRouter.classify("Fix the null pointer bug in authenticate_user")
      %{
        primary_store: :procedural,
        confidence: 0.94,
        reasoning: "Code syntax detected; 'bug' and 'fix' keywords",
        ...
      }

  """
  @spec classify(String.t()) :: decision()
  def classify(query) when is_binary(query) do
    start_time = System.monotonic_time(:microsecond)

    query_lower = String.downcase(query)
    tokens = tokenize(query_lower)

    # Score each store (raw keyword/pattern matching)
    procedural_score = score_procedural(tokens, query_lower)
    semantic_score = score_semantic(tokens, query_lower)
    episodic_score = score_episodic(tokens, query_lower)

    # Phase 3 Learning Loop: Apply feedback-based boosts
    # This adjusts scores based on historical success rates
    boosts = get_feedback_boosts()

    boosted_procedural = procedural_score * Map.get(boosts, :procedural, 1.0)
    boosted_semantic = semantic_score * Map.get(boosts, :semantic, 1.0)
    boosted_episodic = episodic_score * Map.get(boosts, :episodic, 1.0)

    # avoid div/0
    total = boosted_procedural + boosted_semantic + boosted_episodic + 0.01

    scores = %{
      procedural: boosted_procedural / total,
      semantic: boosted_semantic / total,
      episodic: boosted_episodic / total
    }

    {primary_store, confidence} =
      scores
      |> Enum.max_by(fn {_k, v} -> v end)

    secondary_stores =
      scores
      |> Enum.filter(fn {k, v} -> k != primary_store and v > 0.2 end)
      |> Enum.map(fn {k, _v} -> k end)

    reasoning = generate_reasoning(primary_store, tokens)

    # L5: Apply confidence calibration based on historical accuracy
    calibrated_confidence = FeedbackLoop.calibrated_confidence(:classification, confidence)

    # Emit telemetry with feedback info
    duration_us = System.monotonic_time(:microsecond) - start_time
    feedback_applied = boosts != %{procedural: 1.0, semantic: 1.0, episodic: 1.0}
    emit_telemetry(duration_us, primary_store, calibrated_confidence, feedback_applied)

    %{
      primary_store: primary_store,
      secondary_stores: secondary_stores,
      confidence: Float.round(calibrated_confidence, 2),
      raw_confidence: Float.round(confidence, 2),
      reasoning: reasoning,
      requires_synthesis: calibrated_confidence < 0.7 or secondary_stores != [],
      tracking_id: generate_tracking_id(),
      feedback_boosts: boosts
    }
  end

  @doc """
  Record the outcome of a classification decision.

  Call this after the classified query has been processed to provide
  feedback for learning. The FeedbackLoop uses this to improve classification.

  ## Parameters
    - `tracking_id` - The tracking_id from the classify result
    - `outcome` - Map with :success (boolean) and optional details

  ## Example
      decision = MetaCognitiveRouter.classify("Fix the bug")
      # ... process query ...
      MetaCognitiveRouter.record_outcome(decision.tracking_id, %{
        success: true,
        found_result: true,
        user_satisfied: true
      })
  """
  @spec record_outcome(String.t(), map()) :: :ok
  def record_outcome(tracking_id, outcome) when is_binary(tracking_id) and is_map(outcome) do
    # L5: Pass predicted confidence for calibration tracking
    predicted_confidence = Map.get(outcome, :predicted_confidence, nil)

    FeedbackLoop.record_outcome(
      :classification,
      %{
        tracking_id: tracking_id,
        predicted_confidence: predicted_confidence
      },
      outcome
    )
  end

  defp generate_tracking_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp tokenize(text) do
    text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp score_procedural(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @procedural_keywords)

    # Code patterns boost
    code_patterns = [
      ~r/\b(function|method|class|def|fn)\b/,
      ~r/\b(bug|error|fix|debug)\b/,
      ~r/\b(implement|code|compile|runtime)\b/,
      # function calls
      ~r/\([^)]*\)/,
      # snake_case identifiers
      ~r/_[a-z]+/
    ]

    pattern_hits = Enum.count(code_patterns, &Regex.match?(&1, query))

    keyword_hits * 2.0 + pattern_hits * 1.5
  end

  defp score_semantic(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @semantic_keywords)

    # Relationship patterns
    relationship_patterns = [
      ~r/\b(between|relates?|connects?|linked)\b/,
      ~r/\b(depends|requires|uses)\b/,
      ~r/\b(structure|architecture|diagram)\b/
    ]

    pattern_hits = Enum.count(relationship_patterns, &Regex.match?(&1, query))

    keyword_hits * 2.0 + pattern_hits * 1.5
  end

  defp score_episodic(tokens, query) do
    keyword_hits = count_keyword_hits(tokens, @episodic_keywords)

    # Narrative patterns
    narrative_patterns = [
      ~r/\b(remember|recall|when|before)\b/,
      ~r/\b(last time|previously|earlier)\b/,
      ~r/\b(experience|story|happened)\b/,
      ~r/\b(vibe|feel|atmosphere|mood)\b/
    ]

    pattern_hits = Enum.count(narrative_patterns, &Regex.match?(&1, query))

    # Default baseline for general queries
    baseline = 1.0

    keyword_hits * 2.0 + pattern_hits * 1.5 + baseline
  end

  defp count_keyword_hits(tokens, keywords) do
    Enum.count(tokens, &(&1 in keywords))
  end

  defp generate_reasoning(store, tokens) do
    matched_keywords =
      case store do
        :procedural -> Enum.filter(tokens, &(&1 in @procedural_keywords))
        :semantic -> Enum.filter(tokens, &(&1 in @semantic_keywords))
        :episodic -> Enum.filter(tokens, &(&1 in @episodic_keywords))
      end

    store_name = Atom.to_string(store) |> String.capitalize()

    if Enum.empty?(matched_keywords) do
      "#{store_name} store selected as default for general query"
    else
      "#{store_name} store selected; keywords detected: #{Enum.join(matched_keywords, ", ")}"
    end
  end

  @doc """
  Get classification accuracy statistics from FeedbackLoop.

  Returns accuracy rates for each store type based on recorded outcomes.
  Use this to understand how well the router is performing.
  """
  @spec classification_stats() :: map()
  def classification_stats do
    try do
      FeedbackLoop.classification_accuracy()
    rescue
      _ -> %{}
    end
  end

  @doc """
  Get feedback-based boost values for each store.

  Returns a map of boost multipliers based on historical success rates.
  Stores with higher success rates get a boost (max 1.0 + @feedback_boost_weight).
  Falls back to neutral (1.0) if insufficient data.

  Used internally by classify/1 to apply learning-based adjustments.
  """
  @spec get_feedback_boosts() :: map()
  def get_feedback_boosts do
    try do
      accuracy_by_store = FeedbackLoop.classification_accuracy()

      # Check if we have enough samples
      total_samples =
        try do
          FeedbackLoop.stats()
          |> get_in([:by_category, :classification, :total]) || 0
        rescue
          _ -> 0
        end

      if total_samples < @min_feedback_samples do
        # Not enough data, return neutral boosts
        %{procedural: 1.0, semantic: 1.0, episodic: 1.0}
      else
        # Map router stores to FeedbackLoop classification stores
        # Router uses: :procedural, :semantic, :episodic
        # FeedbackLoop may use: :retrieval, :execution, :synthesis, :reasoning
        # We need to create a reasonable mapping
        store_mapping = %{
          # actions -> execution
          procedural: [:execution],
          # facts -> retrieval/synthesis
          semantic: [:retrieval, :synthesis],
          # memories -> retrieval
          episodic: [:retrieval]
        }

        # Calculate average accuracy for each router store based on mapped feedback stores
        Enum.map([:procedural, :semantic, :episodic], fn router_store ->
          mapped_stores = Map.get(store_mapping, router_store, [])

          rates =
            Enum.map(mapped_stores, fn fb_store ->
              Map.get(accuracy_by_store, fb_store, nil)
            end)
            |> Enum.reject(&is_nil/1)

          avg_rate = if rates == [], do: 0.5, else: Enum.sum(rates) / length(rates)

          # Calculate boost: 1.0 + (success_rate - 0.5) * @feedback_boost_weight * 2
          boost = 1.0 + (avg_rate - 0.5) * @feedback_boost_weight * 2
          # Clamp between 0.8 and 1.2
          boost = max(0.8, min(1.2, boost))
          {router_store, Float.round(boost, 3)}
        end)
        |> Map.new()
      end
    rescue
      _ -> %{procedural: 1.0, semantic: 1.0, episodic: 1.0}
    end
  end

  defp emit_telemetry(duration_us, primary_store, confidence, feedback_applied) do
    # Telemetry event for monitoring
    :telemetry.execute(
      [:mimo, :router, :classify],
      %{duration_us: duration_us, confidence: confidence, feedback_applied: feedback_applied},
      %{primary_store: primary_store}
    )

    duration_ms = duration_us / 1000

    if duration_ms > 10 do
      Logger.warning("Router classification slow: #{Float.round(duration_ms, 2)}ms")
    end
  end

  @doc """
  Classify query using semantic embeddings (SPEC-070).

  Uses prototype query embeddings to determine semantic similarity.
  Returns scores for each store based on cosine similarity to prototypes.

  This is slower than keyword-based classification (~200ms on cache miss)
  but provides much better semantic understanding.

  ## Options
  - `:skip_cache` - Skip embedding cache (default: false)
  - `:timeout` - Embedding timeout in ms (default: 5000)

  ## Returns
  Map with similarity scores per store, or {:error, reason} on failure.
  """
  @spec classify_semantic(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify_semantic(query, opts \\ []) when is_binary(query) do
    start_time = System.monotonic_time(:microsecond)

    with {:ok, query_embedding} <- get_query_embedding(query, opts),
         {:ok, prototype_embeddings} <- ensure_prototype_embeddings() do
      # Calculate similarity to each category's prototypes
      scores =
        Enum.map(prototype_embeddings, fn {category, embeddings} ->
          similarities =
            Enum.map(embeddings, fn proto_emb ->
              VectorMath.cosine_similarity(query_embedding, proto_emb)
            end)

          # Use max similarity as the category score
          max_sim = Enum.max(similarities, fn -> 0.0 end)
          {category, max_sim}
        end)
        |> Map.new()

      duration_us = System.monotonic_time(:microsecond) - start_time

      :telemetry.execute(
        [:mimo, :router, :classify_semantic],
        %{duration_us: duration_us},
        %{cache_hit: Keyword.get(opts, :cache_hit, false)}
      )

      {:ok, scores}
    else
      {:error, reason} ->
        Logger.warning("[MetaCognitiveRouter] Semantic classification failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Hybrid classification combining keyword and embedding scores (SPEC-070).

  Blends keyword-based classification (fast, explicit signals) with
  embedding-based classification (slower, semantic understanding).

  Default blend: 60% embedding + 40% keyword (configurable via module attrs).

  Falls back to keyword-only if embedding fails.
  """
  @spec classify_hybrid(String.t(), keyword()) :: decision()
  def classify_hybrid(query, opts \\ []) when is_binary(query) do
    start_time = System.monotonic_time(:microsecond)

    # Get keyword scores (always fast)
    keyword_decision = classify(query)
    keyword_scores = extract_keyword_scores(query)

    # Try embedding scores (may fail or timeout)
    embedding_scores =
      case classify_semantic(query, opts) do
        {:ok, scores} -> scores
        {:error, _} -> nil
      end

    final_decision =
      if embedding_scores do
        # Blend scores
        blended_scores =
          Enum.map([:procedural, :semantic, :episodic], fn store ->
            kw_score = Map.get(keyword_scores, store, 0.0)
            emb_score = Map.get(embedding_scores, store, 0.0)
            blended = @embedding_weight * emb_score + @keyword_weight * kw_score
            {store, blended}
          end)
          |> Map.new()

        # Normalize
        total = Enum.sum(Map.values(blended_scores)) + 0.01
        normalized = Map.new(blended_scores, fn {k, v} -> {k, v / total} end)

        {primary_store, raw_confidence} = Enum.max_by(normalized, fn {_k, v} -> v end)

        # L5: Apply confidence calibration
        calibrated_confidence = FeedbackLoop.calibrated_confidence(:classification, raw_confidence)

        secondary_stores =
          normalized
          |> Enum.filter(fn {k, v} -> k != primary_store and v > 0.2 end)
          |> Enum.map(fn {k, _v} -> k end)

        %{
          primary_store: primary_store,
          secondary_stores: secondary_stores,
          confidence: Float.round(calibrated_confidence, 2),
          raw_confidence: Float.round(raw_confidence, 2),
          reasoning:
            "Hybrid classification (#{round(@embedding_weight * 100)}% semantic + #{round(@keyword_weight * 100)}% keyword)",
          requires_synthesis: calibrated_confidence < 0.7 or secondary_stores != []
        }
      else
        # Fallback to keyword-only
        keyword_decision
      end

    duration_us = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:mimo, :router, :classify_hybrid],
      %{duration_us: duration_us, confidence: final_decision.confidence},
      %{primary_store: final_decision.primary_store, used_embeddings: embedding_scores != nil}
    )

    final_decision
  end

  # Extract raw keyword scores (unnormalized) for blending
  defp extract_keyword_scores(query) do
    query_lower = String.downcase(query)
    tokens = tokenize(query_lower)

    %{
      procedural: score_procedural(tokens, query_lower),
      semantic: score_semantic(tokens, query_lower),
      episodic: score_episodic(tokens, query_lower)
    }
  end

  # Get embedding for query, using cache if available
  defp get_query_embedding(query, opts) do
    skip_cache = Keyword.get(opts, :skip_cache, false)

    if skip_cache do
      LLM.get_embedding(query)
    else
      # Try cache first
      case EmbeddingCache.get(query) do
        {:ok, embedding} ->
          {:ok, embedding}

        :miss ->
          case LLM.get_embedding(query) do
            {:ok, embedding} ->
              EmbeddingCache.put(query, embedding)
              {:ok, embedding}

            error ->
              error
          end
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Ensure prototype embeddings are computed and cached
  defp ensure_prototype_embeddings do
    # Check if we have cached prototypes
    case get_cached_prototypes() do
      {:ok, prototypes} ->
        {:ok, prototypes}

      :miss ->
        # Compute and cache prototypes
        Logger.info("[MetaCognitiveRouter] Computing prototype embeddings...")

        results =
          Enum.map(@prototype_queries, fn {category, queries} ->
            embeddings =
              Enum.map(queries, fn q ->
                case LLM.get_embedding(q) do
                  {:ok, emb} -> emb
                  {:error, _} -> nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            {category, embeddings}
          end)
          |> Map.new()

        # Verify we got embeddings for all categories
        if Enum.all?(results, fn {_cat, embs} -> embs != [] end) do
          cache_prototypes(results)
          {:ok, results}
        else
          {:error, :prototype_embedding_failed}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Cache prototype embeddings in ETS
  defp get_cached_prototypes do
    try do
      case :ets.lookup(@prototype_cache, :prototypes) do
        [{:prototypes, data, timestamp}] ->
          # Check TTL (24 hours)
          if System.monotonic_time(:second) - timestamp < 86_400 do
            {:ok, data}
          else
            :miss
          end

        [] ->
          :miss
      end
    rescue
      ArgumentError ->
        # Table doesn't exist, create it
        Mimo.EtsSafe.ensure_table(@prototype_cache, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true}
        ])

        :miss
    end
  end

  defp cache_prototypes(data) do
    try do
      Mimo.EtsSafe.ensure_table(@prototype_cache, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true}
      ])

      :ets.insert(@prototype_cache, {:prototypes, data, System.monotonic_time(:second)})
    rescue
      _ -> :ok
    end
  end

  @doc """
  Suggest a workflow pattern for a task description.

  Uses the Workflow Predictor to find matching patterns and returns
  a suggestion with confidence and resolved bindings.

  ## Options
  - `:context` - Additional context map for binding resolution
  - `:auto_threshold` - Confidence threshold for auto-execution (default: 0.85)
  - `:suggest_threshold` - Confidence threshold for suggestions (default: 0.5)

  ## Returns
  - `{:ok, suggestion}` with workflow_suggestion() type
  - `{:error, reason}` if prediction fails

  ## Examples

      iex> Mimo.MetaCognitiveRouter.suggest_workflow("Fix the undefined function error in auth.ex")
      {:ok, %{
        type: :auto_execute,
        pattern: %Pattern{name: "debug_error", ...},
        confidence: 0.92,
        bindings: %{"error_message" => "undefined function", "file" => "auth.ex"},
        ...
      }}

  """
  @spec suggest_workflow(String.t(), keyword()) :: {:ok, workflow_suggestion()}
  def suggest_workflow(task_description, opts \\ []) when is_binary(task_description) do
    start_time = System.monotonic_time(:microsecond)

    context = Keyword.get(opts, :context, %{})
    auto_threshold = Keyword.get(opts, :auto_threshold, 0.85)
    suggest_threshold = Keyword.get(opts, :suggest_threshold, 0.5)

    result =
      case Predictor.predict_workflow(task_description, context) do
        {:ok, pattern, confidence, bindings} ->
          suggestion =
            build_suggestion(:auto_execute, pattern, confidence, bindings, auto_threshold)

          {:ok, suggestion}

        {:suggest, patterns} when is_list(patterns) ->
          # Multiple pattern candidates (list of Pattern structs)
          top_pattern = List.first(patterns)

          suggestion = %{
            type: :suggest,
            pattern: top_pattern,
            patterns: patterns,
            confidence: suggest_threshold,
            bindings: %{},
            reason: "Multiple matching patterns found; user selection recommended"
          }

          {:ok, suggestion}

        {:manual, reason} ->
          suggestion = %{
            type: :manual,
            pattern: nil,
            patterns: [],
            confidence: 0.0,
            bindings: %{},
            reason: reason
          }

          {:ok, suggestion}
      end

    # Emit telemetry
    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_workflow_telemetry(duration_us, result)

    result
  end

  defp build_suggestion(_base_type, pattern, confidence, bindings, auto_threshold) do
    # Determine if confidence is high enough for auto-execution
    actual_type = if confidence >= auto_threshold, do: :auto_execute, else: :suggest

    %{
      type: actual_type,
      pattern: pattern,
      patterns: [pattern],
      confidence: Float.round(confidence, 3),
      bindings: bindings,
      reason:
        if(actual_type == :suggest,
          do: "Confidence below auto-execute threshold (#{auto_threshold})",
          else: nil
        )
    }
  end

  defp emit_workflow_telemetry(duration_us, result) do
    {suggestion_type, confidence} =
      case result do
        {:ok, %{type: t, confidence: c}} -> {t, c}
        _ -> {:error, 0.0}
      end

    :telemetry.execute(
      [:mimo, :router, :suggest_workflow],
      %{duration_us: duration_us, confidence: confidence},
      %{suggestion_type: suggestion_type}
    )

    duration_ms = duration_us / 1000

    if duration_ms > 50 do
      Logger.warning("Workflow suggestion slow: #{Float.round(duration_ms, 2)}ms")
    end
  end

  @doc """
  Classify a query and optionally suggest a workflow.

  This is a combined operation that first classifies the query for
  store routing, then if it's procedural, also suggests a workflow.

  ## Returns
  Map with :classification and optionally :workflow_suggestion keys.
  """
  @spec classify_and_suggest(String.t(), keyword()) :: %{
          classification: decision(),
          workflow_suggestion: workflow_suggestion() | nil
        }
  def classify_and_suggest(query, opts \\ []) when is_binary(query) do
    classification = classify(query)

    # Only suggest workflow for procedural queries with decent confidence
    workflow_suggestion =
      if classification.primary_store == :procedural and classification.confidence >= 0.5 do
        {:ok, suggestion} = suggest_workflow(query, opts)
        suggestion
      else
        nil
      end

    %{
      classification: classification,
      workflow_suggestion: workflow_suggestion
    }
  end
end
