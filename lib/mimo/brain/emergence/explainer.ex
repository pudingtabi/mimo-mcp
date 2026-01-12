defmodule Mimo.Brain.Emergence.Explainer do
  @moduledoc """
  SPEC-044 Phase 4.3: Explanation Layer for emergent patterns.

  Generates human-readable explanations and hypotheses for why patterns
  emerged, why they're likely to promote, and what they mean for the system.

  ## Features

  1. **Pattern Explanation**: Explains what a pattern does and why it formed
  2. **Hypothesis Generation**: Uses LLM to generate hypotheses about pattern emergence
  3. **Promotion Reasoning**: Explains why a pattern is ready (or not) for promotion
  4. **Evolution Narrative**: Tells the story of how a pattern evolved over time

  ## Architecture

  ```
  Pattern Data → Explainer → LLM → Human-Readable Insights
                    ↓
               Knowledge Graph (optional storage)
  ```
  """

  require Logger

  alias Mimo.Brain.Emergence.{Pattern, Metrics}
  alias Mimo.Brain.LLM

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Explains a pattern in human-readable terms.

  Returns a structured explanation including:
  - Summary: One-line description of what the pattern does
  - Formation: Why this pattern likely emerged
  - Significance: What this pattern means for the system
  - Recommendation: Suggested next steps

  ## Options
  - `:use_llm` - Use LLM for richer explanations (default: true)
  - `:include_evolution` - Include evolution narrative (default: false)
  - `:include_prediction` - Include promotion prediction (default: true)
  """
  @spec explain(Pattern.t() | binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def explain(pattern_or_id, opts \\ [])

  def explain(%Pattern{} = pattern, opts) do
    use_llm = Keyword.get(opts, :use_llm, true)
    include_evolution = Keyword.get(opts, :include_evolution, false)
    include_prediction = Keyword.get(opts, :include_prediction, true)

    explanation = %{
      pattern_id: pattern.id,
      type: pattern.type,
      summary: generate_summary(pattern),
      formation: explain_formation(pattern),
      significance: assess_significance(pattern),
      recommendation: generate_recommendation(pattern)
    }

    explanation =
      if include_evolution do
        Map.put(explanation, :evolution_narrative, narrate_evolution(pattern))
      else
        explanation
      end

    explanation =
      if include_prediction do
        prediction = Metrics.predict_emergence([pattern])
        Map.put(explanation, :prediction, format_prediction(prediction, pattern))
      else
        explanation
      end

    # Optionally enhance with LLM
    explanation =
      if use_llm do
        case enhance_with_llm(pattern, explanation) do
          {:ok, enhanced} -> enhanced
          {:error, _} -> explanation
        end
      else
        explanation
      end

    {:ok, explanation}
  end

  def explain(pattern_id, opts) when is_binary(pattern_id) do
    case Pattern.get(pattern_id) do
      {:ok, pattern} -> explain(pattern, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates hypotheses about why a pattern emerged.

  Uses LLM to analyze pattern components and context to generate
  plausible hypotheses about the pattern's origin and purpose.

  Returns a list of hypotheses ranked by plausibility.
  """
  @spec hypothesize(Pattern.t() | binary()) :: {:ok, list(map())} | {:error, term()}
  def hypothesize(pattern_or_id)

  def hypothesize(%Pattern{} = pattern) do
    prompt = build_hypothesis_prompt(pattern)

    case LLM.complete(prompt, max_tokens: 500, temperature: 0.3, format: :json) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, hypotheses} when is_list(hypotheses) ->
            {:ok, hypotheses}

          {:ok, %{"hypotheses" => hypotheses}} when is_list(hypotheses) ->
            {:ok, hypotheses}

          {:ok, other} ->
            # Handle single hypothesis or unexpected format
            {:ok, [%{"hypothesis" => to_string(other), "plausibility" => 0.5}]}

          {:error, _} ->
            # LLM didn't return valid JSON, create structured response from text
            {:ok, [%{"hypothesis" => response, "plausibility" => 0.5, "source" => "raw_llm"}]}
        end

      {:error, reason} ->
        Logger.warning("[Explainer] LLM hypothesize failed: #{inspect(reason)}")
        {:ok, generate_fallback_hypotheses(pattern)}
    end
  end

  def hypothesize(pattern_id) when is_binary(pattern_id) do
    case Pattern.get(pattern_id) do
      {:ok, pattern} -> hypothesize(pattern)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Explains why a pattern is (or isn't) ready for promotion.

  Analyzes the pattern against promotion thresholds and provides
  detailed reasoning for each criterion.
  """
  @spec explain_promotion_readiness(Pattern.t() | binary()) :: {:ok, map()} | {:error, term()}
  def explain_promotion_readiness(pattern_or_id)

  def explain_promotion_readiness(%Pattern{} = pattern) do
    thresholds = %{
      min_occurrences: 10,
      min_success_rate: 0.8,
      min_strength: 0.75
    }

    criteria = [
      analyze_criterion(:occurrences, pattern.occurrences, thresholds.min_occurrences),
      analyze_criterion(:success_rate, pattern.success_rate, thresholds.min_success_rate),
      analyze_criterion(:strength, pattern.strength, thresholds.min_strength)
    ]

    all_met = Enum.all?(criteria, & &1.met)

    explanation = %{
      pattern_id: pattern.id,
      ready_for_promotion: all_met,
      criteria: criteria,
      overall_assessment: generate_promotion_assessment(pattern, criteria, all_met),
      next_steps: generate_promotion_next_steps(pattern, criteria)
    }

    {:ok, explanation}
  end

  def explain_promotion_readiness(pattern_id) when is_binary(pattern_id) do
    case Pattern.get(pattern_id) do
      {:ok, pattern} -> explain_promotion_readiness(pattern)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Explains multiple patterns and their relationships.

  Useful for understanding a collection of related patterns.
  """
  @spec explain_batch([Pattern.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def explain_batch(patterns, opts \\ []) when is_list(patterns) do
    explanations =
      patterns
      |> Enum.map(fn pattern ->
        case explain(pattern, Keyword.put(opts, :use_llm, false)) do
          {:ok, exp} -> exp
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    summary = %{
      total_patterns: length(patterns),
      explained_count: length(explanations),
      by_type: group_by_type(explanations),
      overall_health: assess_overall_health(patterns),
      relationships: find_pattern_relationships(patterns)
    }

    {:ok, %{explanations: explanations, summary: summary}}
  end

  # ─────────────────────────────────────────────────────────────────
  # Summary Generation
  # ─────────────────────────────────────────────────────────────────

  defp generate_summary(%Pattern{type: type, description: description, occurrences: occ}) do
    type_label = type_to_label(type)

    "#{type_label} pattern (#{occ} occurrences): #{truncate(description, 100)}"
  end

  defp type_to_label(:workflow), do: "Workflow"
  defp type_to_label(:inference), do: "Inference"
  defp type_to_label(:heuristic), do: "Heuristic"
  defp type_to_label(:skill), do: "Skill"
  defp type_to_label(other), do: to_string(other) |> String.capitalize()

  # ─────────────────────────────────────────────────────────────────
  # Formation Explanation
  # ─────────────────────────────────────────────────────────────────

  defp explain_formation(%Pattern{
         type: type,
         components: components,
         trigger_conditions: triggers,
         first_seen: first_seen,
         occurrences: occurrences
       }) do
    component_count = length(components || [])
    trigger_count = length(triggers || [])
    age_days = age_in_days(first_seen)

    %{
      origin: formation_origin(type, component_count),
      contributing_factors: [
        "#{component_count} interacting components",
        "#{trigger_count} trigger conditions identified",
        "Pattern observed #{occurrences} times over #{age_days} days"
      ],
      emergence_type: categorize_emergence(type, occurrences, age_days)
    }
  end

  defp formation_origin(:workflow, component_count) when component_count > 3 do
    "Complex multi-step workflow emerged from repeated task execution"
  end

  defp formation_origin(:workflow, _) do
    "Simple workflow pattern emerged from repeated action sequence"
  end

  defp formation_origin(:inference, _) do
    "Inference pattern emerged from connecting disparate information sources"
  end

  defp formation_origin(:heuristic, _) do
    "Heuristic emerged from observing patterns in successful outcomes"
  end

  defp formation_origin(:skill, _) do
    "Skill emerged from practicing and refining a specific capability"
  end

  defp formation_origin(_, _) do
    "Pattern emerged from system interactions"
  end

  defp categorize_emergence(_type, occurrences, age_days) when occurrences > 20 and age_days < 7 do
    :rapid_emergence
  end

  defp categorize_emergence(_type, occurrences, age_days) when occurrences > 10 and age_days > 14 do
    :gradual_emergence
  end

  defp categorize_emergence(_type, _occurrences, _age_days) do
    :normal_emergence
  end

  # ─────────────────────────────────────────────────────────────────
  # Significance Assessment
  # ─────────────────────────────────────────────────────────────────

  defp assess_significance(%Pattern{
         strength: strength,
         success_rate: success_rate,
         occurrences: occurrences,
         type: type
       }) do
    level = calculate_significance_level(strength, success_rate, occurrences)

    %{
      level: level,
      impact: describe_impact(level, type),
      confidence: calculate_confidence(occurrences, success_rate)
    }
  end

  defp calculate_significance_level(strength, success_rate, occurrences) do
    score = strength * 0.4 + success_rate * 0.4 + min(occurrences / 20, 1.0) * 0.2

    cond do
      score >= 0.8 -> :high
      score >= 0.5 -> :medium
      true -> :low
    end
  end

  defp describe_impact(:high, :workflow) do
    "This workflow significantly improves task completion efficiency"
  end

  defp describe_impact(:high, :inference) do
    "This inference pattern enables novel insights from existing knowledge"
  end

  defp describe_impact(:high, :heuristic) do
    "This heuristic provides reliable decision-making guidance"
  end

  defp describe_impact(:high, :skill) do
    "This skill represents a mature capability ready for regular use"
  end

  defp describe_impact(:medium, type) do
    "This #{type} pattern shows promise and may become more significant"
  end

  defp describe_impact(:low, type) do
    "This #{type} pattern is emerging but not yet well-established"
  end

  defp calculate_confidence(occurrences, success_rate) when occurrences >= 10 do
    # More data = more confident
    base = min(occurrences / 20, 1.0) * 0.5
    # Higher success rate = more confident
    success_factor = success_rate * 0.5
    Float.round(base + success_factor, 2)
  end

  defp calculate_confidence(_occurrences, _success_rate), do: 0.3

  # ─────────────────────────────────────────────────────────────────
  # Recommendation Generation
  # ─────────────────────────────────────────────────────────────────

  defp generate_recommendation(%Pattern{
         status: :promoted
       }) do
    "This pattern has been promoted to a capability. Monitor its usage."
  end

  defp generate_recommendation(%Pattern{
         strength: strength,
         success_rate: success_rate,
         occurrences: occurrences
       })
       when strength >= 0.75 and success_rate >= 0.8 and occurrences >= 10 do
    "Pattern is ready for promotion. Consider promoting to explicit capability."
  end

  defp generate_recommendation(%Pattern{
         strength: strength,
         occurrences: occurrences
       })
       when strength < 0.5 and occurrences < 5 do
    "Pattern is still forming. Continue observing for more occurrences."
  end

  defp generate_recommendation(%Pattern{
         success_rate: success_rate
       })
       when success_rate < 0.5 do
    "Pattern has low success rate. Investigate failure cases before promotion."
  end

  defp generate_recommendation(_pattern) do
    "Pattern is developing. Monitor for continued growth and stability."
  end

  # ─────────────────────────────────────────────────────────────────
  # Evolution Narrative
  # ─────────────────────────────────────────────────────────────────

  defp narrate_evolution(%Pattern{
         evolution: evolution,
         first_seen: first_seen,
         last_seen: last_seen
       })
       when is_list(evolution) and evolution != [] do
    age = age_in_days(first_seen)
    last_activity = age_in_days(last_seen)

    stages =
      evolution
      |> Enum.take(5)
      |> Enum.map(&format_evolution_event/1)

    %{
      age_days: age,
      days_since_last_activity: last_activity,
      evolution_stages: stages,
      trajectory: determine_trajectory(evolution)
    }
  end

  defp narrate_evolution(_pattern) do
    %{
      age_days: 0,
      days_since_last_activity: 0,
      evolution_stages: [],
      trajectory: :unknown
    }
  end

  defp format_evolution_event(%{"timestamp" => ts, "event" => event}) do
    "#{ts}: #{event}"
  end

  defp format_evolution_event(event) when is_binary(event), do: event
  defp format_evolution_event(event), do: inspect(event)

  defp determine_trajectory(evolution) when length(evolution) >= 3 do
    # Look at strength/occurrences trend in recent events
    recent = Enum.take(evolution, -3)

    strengths =
      recent
      |> Enum.map(&extract_strength/1)
      |> Enum.reject(&is_nil/1)

    case strengths do
      [a, b, c] when c > b and b > a -> :growing
      [a, b, c] when c < b and b < a -> :declining
      _ -> :stable
    end
  end

  defp determine_trajectory(_), do: :forming

  defp extract_strength(%{"strength" => s}) when is_number(s), do: s
  defp extract_strength(_), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Promotion Analysis
  # ─────────────────────────────────────────────────────────────────

  defp analyze_criterion(:occurrences, actual, threshold) do
    met = actual >= threshold
    gap = threshold - actual

    %{
      criterion: :occurrences,
      actual: actual,
      threshold: threshold,
      met: met,
      gap: if(met, do: 0, else: gap),
      explanation:
        if met do
          "Pattern observed #{actual} times (threshold: #{threshold})"
        else
          "Need #{gap} more occurrences (#{actual}/#{threshold})"
        end
    }
  end

  defp analyze_criterion(:success_rate, actual, threshold) do
    met = actual >= threshold
    gap = Float.round(threshold - actual, 2)

    %{
      criterion: :success_rate,
      actual: Float.round(actual, 2),
      threshold: threshold,
      met: met,
      gap: if(met, do: 0.0, else: gap),
      explanation:
        if met do
          "Success rate #{Float.round(actual * 100, 1)}% exceeds #{threshold * 100}%"
        else
          "Success rate #{Float.round(actual * 100, 1)}% below #{threshold * 100}% threshold"
        end
    }
  end

  defp analyze_criterion(:strength, actual, threshold) do
    met = actual >= threshold
    gap = Float.round(threshold - actual, 2)

    %{
      criterion: :strength,
      actual: Float.round(actual, 2),
      threshold: threshold,
      met: met,
      gap: if(met, do: 0.0, else: gap),
      explanation:
        if met do
          "Pattern strength #{Float.round(actual, 2)} exceeds threshold"
        else
          "Pattern strength #{Float.round(actual, 2)} below #{threshold} threshold"
        end
    }
  end

  defp generate_promotion_assessment(pattern, _criteria, true) do
    "Pattern '#{truncate(pattern.description, 50)}' meets all promotion criteria and is ready to become an explicit capability."
  end

  defp generate_promotion_assessment(pattern, criteria, false) do
    unmet = Enum.filter(criteria, &(not &1.met))
    unmet_names = Enum.map_join(unmet, ", ", & &1.criterion)

    "Pattern '#{truncate(pattern.description, 50)}' is not ready for promotion. Unmet criteria: #{unmet_names}"
  end

  defp generate_promotion_next_steps(_pattern, criteria) do
    unmet = Enum.filter(criteria, &(not &1.met))

    if Enum.empty?(unmet) do
      ["Run `emergence_promote` to promote this pattern"]
    else
      Enum.map(unmet, fn criterion ->
        case criterion.criterion do
          :occurrences -> "Wait for #{criterion.gap} more pattern occurrences"
          :success_rate -> "Improve success rate by #{Float.round(criterion.gap * 100, 1)}%"
          :strength -> "Increase pattern strength by #{criterion.gap}"
        end
      end)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # LLM Enhancement
  # ─────────────────────────────────────────────────────────────────

  defp enhance_with_llm(pattern, base_explanation) do
    prompt = """
    Analyze this emergent pattern and provide deeper insights:

    Pattern Type: #{pattern.type}
    Description: #{pattern.description}
    Components: #{inspect(pattern.components)}
    Trigger Conditions: #{inspect(pattern.trigger_conditions)}
    Strength: #{pattern.strength}
    Success Rate: #{pattern.success_rate}
    Occurrences: #{pattern.occurrences}

    Current Explanation:
    #{inspect(base_explanation)}

    Provide a brief (2-3 sentences) insight about:
    1. What makes this pattern unique or valuable
    2. Potential risks or limitations
    3. How this pattern might evolve

    Respond in JSON format:
    {"insight": "...", "risks": "...", "evolution_prediction": "..."}
    """

    case LLM.complete(prompt, max_tokens: 300, temperature: 0.2, format: :json) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, insights} ->
            {:ok, Map.put(base_explanation, :llm_insights, insights)}

          {:error, _} ->
            {:ok, Map.put(base_explanation, :llm_insights, %{"insight" => response})}
        end

      {:error, reason} ->
        Logger.debug("[Explainer] LLM enhancement failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Hypothesis Generation
  # ─────────────────────────────────────────────────────────────────

  defp build_hypothesis_prompt(%Pattern{
         type: type,
         description: description,
         components: components,
         trigger_conditions: triggers,
         occurrences: occurrences,
         success_rate: success_rate
       }) do
    """
    Analyze why this emergent pattern might have formed:

    Pattern Type: #{type}
    Description: #{description}
    Components: #{inspect(components)}
    Trigger Conditions: #{inspect(triggers)}
    Occurrences: #{occurrences}
    Success Rate: #{Float.round(success_rate * 100, 1)}%

    Generate 3 hypotheses about:
    1. Why this pattern emerged (root cause)
    2. What user need it addresses
    3. What system behavior enabled it

    Respond in JSON format:
    {"hypotheses": [
      {"hypothesis": "...", "plausibility": 0.8, "category": "root_cause"},
      {"hypothesis": "...", "plausibility": 0.7, "category": "user_need"},
      {"hypothesis": "...", "plausibility": 0.6, "category": "system_behavior"}
    ]}
    """
  end

  defp generate_fallback_hypotheses(%Pattern{type: type, occurrences: occurrences}) do
    [
      %{
        "hypothesis" =>
          "Pattern emerged from repeated #{type} interactions (#{occurrences} occurrences)",
        "plausibility" => 0.5,
        "category" => "statistical"
      }
    ]
  end

  # ─────────────────────────────────────────────────────────────────
  # Batch Helpers
  # ─────────────────────────────────────────────────────────────────

  defp group_by_type(explanations) do
    explanations
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, exps} -> {type, length(exps)} end)
    |> Map.new()
  end

  defp assess_overall_health(patterns) do
    if Enum.empty?(patterns) do
      %{status: :unknown, active_count: 0, avg_strength: 0.0}
    else
      active = Enum.count(patterns, &(&1.status == :active))
      avg_strength = Enum.map(patterns, & &1.strength) |> Enum.sum() |> Kernel./(length(patterns))

      status =
        cond do
          avg_strength >= 0.7 and active >= 3 -> :healthy
          avg_strength >= 0.5 -> :developing
          true -> :nascent
        end

      %{
        status: status,
        active_count: active,
        avg_strength: Float.round(avg_strength, 2)
      }
    end
  end

  defp find_pattern_relationships(patterns) when length(patterns) < 2, do: []

  defp find_pattern_relationships(patterns) do
    # Find patterns with overlapping components
    patterns
    |> Enum.with_index()
    |> Enum.flat_map(fn {p1, i} ->
      patterns
      |> Enum.drop(i + 1)
      |> Enum.filter(fn p2 ->
        overlap = component_overlap(p1.components || [], p2.components || [])
        overlap > 0.3
      end)
      |> Enum.map(fn p2 ->
        %{
          pattern_a: p1.id,
          pattern_b: p2.id,
          relationship: :shared_components
        }
      end)
    end)
  end

  defp component_overlap([], _), do: 0.0
  defp component_overlap(_, []), do: 0.0

  defp component_overlap(a, b) do
    a_set = MapSet.new(a, &component_key/1)
    b_set = MapSet.new(b, &component_key/1)
    intersection = MapSet.intersection(a_set, b_set) |> MapSet.size()
    union = MapSet.union(a_set, b_set) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end

  defp component_key(%{"name" => name}), do: name
  defp component_key(%{"tool" => tool}), do: tool
  defp component_key(other), do: inspect(other)

  # ─────────────────────────────────────────────────────────────────
  # Prediction Formatting
  # ─────────────────────────────────────────────────────────────────

  defp format_prediction(%{predictions: predictions}, pattern) do
    case Enum.find(predictions, &(&1.pattern_id == pattern.id)) do
      nil ->
        %{available: false, reason: "No prediction available"}

      pred ->
        %{
          available: true,
          eta_days: pred.eta_days,
          confidence: pred.confidence,
          limiting_factor: pred.limiting_factor,
          velocity_rate: pred.velocity_rate
        }
    end
  end

  defp format_prediction(_, _), do: %{available: false, reason: "Prediction data unavailable"}

  # ─────────────────────────────────────────────────────────────────
  # Utilities
  # ─────────────────────────────────────────────────────────────────

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp age_in_days(nil), do: 0

  defp age_in_days(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :day)
  end
end
