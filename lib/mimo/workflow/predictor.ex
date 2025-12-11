defmodule Mimo.Workflow.Predictor do
  @moduledoc """
  SPEC-053 Phase 2: Predictive Tool Chaining Engine

  Predicts the optimal workflow pattern for a given task description
  using feature extraction, pattern matching, and confidence scoring.

  ## Features

  - Task description embedding (using existing LLM context)
  - Context-aware pattern matching
  - Confidence scoring based on success rates
  - Dynamic parameter binding resolution

  ## Usage

      {:ok, pattern, confidence, bindings} = Predictor.predict_workflow(
        "Fix the null pointer error in auth.ts",
        %{current_file: "src/auth.ts", error_message: "undefined is not a function"}
      )
  """
  require Logger

  alias Mimo.Workflow.{Pattern, PatternRegistry, BindingsResolver}

  # Minimum confidence for auto-execution
  @auto_execute_threshold 0.80

  # Minimum confidence for suggestion
  @suggestion_threshold 0.50

  # Maximum patterns to suggest
  @max_suggestions 3

  @type prediction_result ::
          {:ok, Pattern.t(), float(), map()}
          | {:suggest, [Pattern.t()]}
          | {:manual, String.t()}

  @type context :: %{
          optional(:current_file) => String.t(),
          optional(:error_message) => String.t(),
          optional(:task_description) => String.t(),
          optional(:recent_tools) => [String.t()],
          optional(:project_type) => String.t(),
          optional(:model_type) => String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Predicts the best workflow for a task description.

  ## Parameters

    * `description` - Task description or query
    * `context` - Current execution context

  ## Returns

    * `{:ok, pattern, confidence, bindings}` - High confidence, ready for auto-execution
    * `{:suggest, patterns}` - Medium confidence, suggest top patterns
    * `{:manual, reason}` - Low confidence, manual control needed
  """
  @spec predict_workflow(String.t(), context()) :: prediction_result()
  def predict_workflow(description, context \\ %{}) do
    # Extract features from description and context
    features = extract_features(description, context)

    # Get all candidate patterns
    candidates = get_candidate_patterns(features)

    # Score and rank candidates
    scored = score_candidates(candidates, features, context)

    # Select based on confidence
    select_prediction(scored)
  end

  @doc """
  Returns whether a prediction should auto-execute.
  """
  @spec should_auto_execute?(float()) :: boolean()
  def should_auto_execute?(confidence) do
    confidence >= @auto_execute_threshold
  end

  @doc """
  Gets the confidence threshold for auto-execution.
  """
  @spec auto_execute_threshold() :: float()
  def auto_execute_threshold, do: @auto_execute_threshold

  # ============================================================================
  # Feature Extraction
  # ============================================================================

  defp extract_features(description, context) do
    description_lower = String.downcase(description)
    tokens = tokenize(description_lower)

    %{
      description: description,
      description_lower: description_lower,
      tokens: tokens,
      intent: detect_intent(tokens, description_lower),
      entities: extract_entities(description, context),
      context_signals: extract_context_signals(context),
      complexity: estimate_complexity(tokens, description_lower)
    }
  end

  defp tokenize(text) do
    text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp detect_intent(tokens, description) do
    cond do
      has_debug_intent?(tokens, description) -> :debug
      has_edit_intent?(tokens, description) -> :edit
      has_navigation_intent?(tokens, description) -> :navigate
      has_onboarding_intent?(tokens, description) -> :onboard
      has_context_intent?(tokens, description) -> :context
      true -> :unknown
    end
  end

  defp has_debug_intent?(tokens, desc) do
    debug_keywords = ~w(debug fix error bug crash issue problem exception undefined null)
    has_any_keyword?(tokens, debug_keywords) or Regex.match?(~r/\b(fix|debug|error)\b/i, desc)
  end

  defp has_edit_intent?(tokens, desc) do
    edit_keywords = ~w(edit modify change update refactor add remove rename replace)
    has_any_keyword?(tokens, edit_keywords) or Regex.match?(~r/\b(edit|change|modify)\b/i, desc)
  end

  defp has_navigation_intent?(tokens, desc) do
    nav_keywords = ~w(find where definition reference usage call uses called)
    has_any_keyword?(tokens, nav_keywords) or Regex.match?(~r/\b(find|where|definition)\b/i, desc)
  end

  defp has_onboarding_intent?(tokens, desc) do
    onboard_keywords = ~w(onboard setup initialize new project start)
    has_any_keyword?(tokens, onboard_keywords) or Regex.match?(~r/\b(onboard|setup|new project)\b/i, desc)
  end

  defp has_context_intent?(tokens, desc) do
    context_keywords = ~w(understand context explain how what architecture)
    has_any_keyword?(tokens, context_keywords) or Regex.match?(~r/\b(understand|context|explain)\b/i, desc)
  end

  defp has_any_keyword?(tokens, keywords) do
    Enum.any?(tokens, &(&1 in keywords))
  end

  defp extract_entities(description, context) do
    %{
      file_paths: extract_file_paths(description, context),
      symbol_names: extract_symbol_names(description),
      error_types: extract_error_types(description, context)
    }
  end

  defp extract_file_paths(description, context) do
    # Extract from description
    regex = ~r/[\w\/\-\.]+\.(ts|js|ex|py|rs|go|rb|java|cpp|c|h)/i
    from_desc = Regex.scan(regex, description) |> Enum.map(&hd/1)

    # Add from context
    from_context =
      [context[:current_file], context[:target_file]]
      |> Enum.filter(& &1)

    Enum.uniq(from_desc ++ from_context)
  end

  defp extract_symbol_names(description) do
    # Match camelCase, snake_case, PascalCase identifiers
    regex = ~r/\b([a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*|[a-z]+_[a-z_]+|[A-Z][a-zA-Z0-9]+)\b/
    Regex.scan(regex, description) |> Enum.map(&hd/1) |> Enum.uniq()
  end

  defp extract_error_types(description, context) do
    error_patterns = [
      {~r/null\s*(pointer|reference)/i, :null_pointer},
      {~r/undefined\s*(is not|function)/i, :undefined_error},
      {~r/type\s*error/i, :type_error},
      {~r/syntax\s*error/i, :syntax_error},
      {~r/compilation?\s*(error|failed)/i, :compile_error},
      {~r/runtime\s*error/i, :runtime_error}
    ]

    text = "#{description} #{context[:error_message] || ""}"

    error_patterns
    |> Enum.filter(fn {pattern, _} -> Regex.match?(pattern, text) end)
    |> Enum.map(fn {_, type} -> type end)
  end

  defp extract_context_signals(context) do
    %{
      has_error: context[:error_message] != nil,
      has_file: context[:current_file] != nil,
      has_recent_tools: (context[:recent_tools] || []) != [],
      recent_tool_count: length(context[:recent_tools] || []),
      model_type: context[:model_type]
    }
  end

  defp estimate_complexity(tokens, _description) do
    cond do
      length(tokens) > 30 -> :high
      length(tokens) > 15 -> :medium
      true -> :low
    end
  end

  # ============================================================================
  # Pattern Matching
  # ============================================================================

  defp get_candidate_patterns(features) do
    # Get all patterns from registry
    all_patterns = PatternRegistry.list_patterns()

    # Filter by intent if we have a strong signal
    case features.intent do
      :unknown ->
        all_patterns

      intent ->
        intent_tags = intent_to_tags(intent)

        matching =
          Enum.filter(all_patterns, fn p ->
            has_matching_tags?(p, intent_tags)
          end)

        # Fall back to all if no matches
        if Enum.empty?(matching), do: all_patterns, else: matching
    end
  end

  defp intent_to_tags(:debug), do: ["debugging", "error-handling", "code-fix"]
  defp intent_to_tags(:edit), do: ["editing", "file-operations", "code-modification"]
  defp intent_to_tags(:navigate), do: ["navigation", "code-analysis", "understanding"]
  defp intent_to_tags(:onboard), do: ["onboarding", "initialization", "project-setup"]
  defp intent_to_tags(:context), do: ["context", "preparation", "complex-tasks"]
  defp intent_to_tags(_), do: []

  defp has_matching_tags?(pattern, tags) do
    pattern_tags = pattern.tags || []
    Enum.any?(tags, &(&1 in pattern_tags))
  end

  # ============================================================================
  # Scoring
  # ============================================================================

  defp score_candidates(candidates, features, context) do
    candidates
    |> Enum.map(fn pattern ->
      score = calculate_pattern_score(pattern, features, context)
      {pattern, score}
    end)
    |> Enum.sort_by(fn {_, score} -> -score end)
  end

  defp calculate_pattern_score(pattern, features, context) do
    # Base score from intent match
    intent_score = score_intent_match(pattern, features.intent)

    # Historical success rate
    success_score = pattern.success_rate * 0.25

    # Entity match score
    entity_score = score_entity_match(pattern, features.entities) * 0.15

    # Context relevance score
    context_score = score_context_relevance(pattern, context) * 0.15

    # Recency and usage score
    usage_score = score_usage(pattern) * 0.05

    # Combined score
    intent_score * 0.40 + success_score + entity_score + context_score + usage_score
  end

  defp score_intent_match(pattern, intent) do
    expected_tags = intent_to_tags(intent)

    if Enum.empty?(expected_tags) do
      0.5
    else
      matches = Enum.count(pattern.tags || [], &(&1 in expected_tags))
      min(matches / length(expected_tags), 1.0)
    end
  end

  defp score_entity_match(pattern, entities) do
    # Check if pattern steps match extracted entities
    step_tools =
      pattern.steps
      |> Enum.map(fn s -> s["tool"] || s[:tool] end)
      |> Enum.uniq()

    entity_signals = [
      if(length(entities.file_paths) > 0, do: "file", else: nil),
      if(length(entities.symbol_names) > 0, do: "code", else: nil),
      if(length(entities.error_types) > 0, do: "code", else: nil)
    ] |> Enum.filter(& &1)

    matches = Enum.count(entity_signals, &(&1 in step_tools))
    if length(entity_signals) > 0, do: matches / length(entity_signals), else: 0.5
  end

  defp score_context_relevance(pattern, context) do
    signals = []

    # Boost if we have an error and pattern handles errors
    signals =
      if context[:error_message] && has_tag?(pattern, "debugging") do
        [0.3 | signals]
      else
        signals
      end

    # Boost if we have a file and pattern handles files
    signals =
      if context[:current_file] && has_tag?(pattern, "file-operations") do
        [0.2 | signals]
      else
        signals
      end

    if Enum.empty?(signals), do: 0.5, else: Enum.sum(signals) / length(signals)
  end

  defp has_tag?(pattern, tag) do
    tag in (pattern.tags || [])
  end

  defp score_usage(pattern) do
    # Favor recently used, frequently used patterns
    usage_factor = min(pattern.usage_count / 100, 1.0)

    recency_factor =
      case pattern.last_used do
        nil ->
          0.0

        last_used ->
          hours_ago = DateTime.diff(DateTime.utc_now(), last_used, :hour)
          max(1.0 - hours_ago / 168, 0.0)
      end

    usage_factor * 0.5 + recency_factor * 0.5
  end

  # ============================================================================
  # Selection
  # ============================================================================

  defp select_prediction([]), do: {:manual, "No patterns available"}

  defp select_prediction([{top_pattern, top_score} | rest]) do
    cond do
      top_score >= @auto_execute_threshold ->
        # High confidence - resolve bindings and return for auto-execution
        bindings = BindingsResolver.resolve(top_pattern, %{})
        {:ok, top_pattern, top_score, bindings}

      top_score >= @suggestion_threshold ->
        # Medium confidence - suggest top patterns
        suggestions =
          [{top_pattern, top_score} | Enum.take(rest, @max_suggestions - 1)]
          |> Enum.map(fn {p, _} -> p end)

        {:suggest, suggestions}

      true ->
        {:manual, "Confidence too low (#{Float.round(top_score, 2)})"}
    end
  end
end
