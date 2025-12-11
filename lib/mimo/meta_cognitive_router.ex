defmodule Mimo.MetaCognitiveRouter do
  @moduledoc """
  Meta-Cognitive Router: Intelligent query classification layer.

  Routes natural language inputs to the appropriate store:
  - Episodic Store (vector): Narrative, experiential queries
  - Semantic Store (graph): Logic, relationship queries  
  - Procedural Store (rules): Code, procedure queries

  SPEC-053: Also provides workflow prediction and suggestion.

  Ref: Universal Aperture TDD - preserves the routing layer while enabling multi-protocol access.
  """
  require Logger

  alias Mimo.Workflow.{Predictor, Pattern}

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

  # Keyword patterns for classification
  @procedural_keywords ~w(code bug fix function method class implement compile error syntax)
  @semantic_keywords ~w(relationship between depends structure architecture graph linked)
  @episodic_keywords ~w(remember when before earlier previously history past experience)

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

    # Score each store
    procedural_score = score_procedural(tokens, query_lower)
    semantic_score = score_semantic(tokens, query_lower)
    episodic_score = score_episodic(tokens, query_lower)

    # avoid div/0
    total = procedural_score + semantic_score + episodic_score + 0.01

    scores = %{
      procedural: procedural_score / total,
      semantic: semantic_score / total,
      episodic: episodic_score / total
    }

    {primary_store, confidence} =
      scores
      |> Enum.max_by(fn {_k, v} -> v end)

    secondary_stores =
      scores
      |> Enum.filter(fn {k, v} -> k != primary_store and v > 0.2 end)
      |> Enum.map(fn {k, _v} -> k end)

    reasoning = generate_reasoning(primary_store, tokens)

    # Emit telemetry
    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(duration_us, primary_store, confidence)

    %{
      primary_store: primary_store,
      secondary_stores: secondary_stores,
      confidence: Float.round(confidence, 2),
      reasoning: reasoning,
      requires_synthesis: confidence < 0.7 or length(secondary_stores) > 0
    }
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

  defp emit_telemetry(duration_us, primary_store, confidence) do
    # Telemetry event for monitoring
    :telemetry.execute(
      [:mimo, :router, :classify],
      %{duration_us: duration_us, confidence: confidence},
      %{primary_store: primary_store}
    )

    duration_ms = duration_us / 1000

    if duration_ms > 10 do
      Logger.warning("Router classification slow: #{Float.round(duration_ms, 2)}ms")
    end
  end

  # =============================================================================
  # SPEC-053: Workflow Prediction & Suggestion
  # =============================================================================

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
