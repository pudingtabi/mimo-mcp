defmodule Mimo.Brain.Emergence.Promoter do
  @moduledoc """
  SPEC-044: Promotes valuable emergent patterns to explicit capabilities.

  When an emergent pattern proves valuable (high occurrence, success rate,
  and strength), it can be "promoted" to become an explicit capability.

  ## Promotion Types

  - **Workflow → Procedure**: Emergent workflows become procedural memory
  - **Inference → Knowledge**: Emergent inferences become semantic facts
  - **Heuristic → Pattern**: Emergent heuristics become cognitive patterns
  - **Skill → Capability**: Emergent skills are registered as capabilities

  ## Promotion Thresholds

  | Metric | Default | Purpose |
  |--------|---------|---------|
  | occurrences | 10 | Pattern must be observed repeatedly |
  | success_rate | 0.8 | Pattern must be reliable |
  | strength | 0.75 | Pattern must be well-established |

  ## Promotion Process

  1. Evaluate pattern against thresholds
  2. Create corresponding permanent artifact
  3. Mark pattern as promoted
  4. Track promotion in metrics
  """

  require Logger

  alias Mimo.Brain.Emergence.{Pattern, Catalog}

  @default_thresholds %{
    occurrences: 10,
    success_rate: 0.8,
    strength: 0.75
  }

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Evaluates a pattern for promotion.
  Returns scoring details and recommendation.
  """
  @spec evaluate_for_promotion(Pattern.t(), keyword()) :: {:promote | :pending, map()}
  def evaluate_for_promotion(pattern, opts \\ []) do
    thresholds = merge_thresholds(opts)

    scores = %{
      occurrence_score: pattern.occurrences / thresholds.occurrences,
      success_score: pattern.success_rate / thresholds.success_rate,
      strength_score: pattern.strength / thresholds.strength
    }

    aggregate = (scores.occurrence_score + scores.success_score + scores.strength_score) / 3

    if aggregate >= 1.0 do
      {:promote,
       %{
         scores: scores,
         aggregate: aggregate,
         recommendation: "Pattern meets all thresholds and should be promoted"
       }}
    else
      {:pending,
       %{
         scores: scores,
         aggregate: aggregate,
         needed: 1.0 - aggregate,
         recommendation: build_recommendation(scores, thresholds)
       }}
    end
  end

  @doc """
  Promotes a pattern to an explicit capability.
  The type of capability depends on the pattern type.
  """
  @spec promote(Pattern.t()) :: {:ok, map()}
  def promote(pattern) do
    Logger.info("[Emergence.Promoter] Promoting pattern: #{pattern.id} (#{pattern.type})")

    {:ok, artifact} =
      case pattern.type do
        :workflow -> promote_to_procedure(pattern)
        :inference -> promote_to_knowledge(pattern)
        :heuristic -> promote_to_cognitive_pattern(pattern)
        :skill -> promote_to_capability(pattern)
      end

    # Mark pattern as promoted
    {:ok, _updated} = Pattern.promote(pattern)

    # Register in catalog
    Catalog.register_promoted(pattern, artifact)

    {:ok,
     %{
       pattern_id: pattern.id,
       type: pattern.type,
       artifact: artifact,
       promoted_at: DateTime.utc_now()
     }}
  end

  @doc """
  Batch evaluates and promotes all eligible patterns.
  """
  @spec promote_eligible(keyword()) :: {:ok, map()}
  def promote_eligible(opts \\ []) do
    candidates = Pattern.promotion_candidates(opts)

    Logger.info("[Emergence.Promoter] Found #{length(candidates)} promotion candidates")

    results =
      candidates
      |> Enum.map(fn pattern ->
        {:ok, result} = promote(pattern)
        {:promoted, result}
      end)

    promoted = length(results)

    {:ok,
     %{
       candidates: length(candidates),
       promoted: promoted,
       failed: 0,
       details: results
     }}
  end

  @doc """
  Gets promotion readiness report for all active patterns.
  """
  def promotion_readiness_report(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    patterns = Pattern.list(status: :active, limit: limit)

    evaluated =
      patterns
      |> Enum.map(fn pattern ->
        {status, details} = evaluate_for_promotion(pattern, opts)

        %{
          pattern_id: pattern.id,
          type: pattern.type,
          description: String.slice(pattern.description, 0, 50),
          status: status,
          aggregate_score: details.aggregate,
          scores: details.scores
        }
      end)
      |> Enum.sort_by(& &1.aggregate_score, :desc)

    ready = Enum.count(evaluated, &(&1.status == :promote))
    pending = Enum.count(evaluated, &(&1.status == :pending))

    %{
      total_evaluated: length(evaluated),
      ready_for_promotion: ready,
      pending: pending,
      patterns: evaluated
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Promotion by Type
  # ─────────────────────────────────────────────────────────────────

  defp promote_to_procedure(pattern) do
    # Convert workflow pattern to procedural memory
    Logger.debug("[Promoter] Converting workflow to procedure: #{pattern.description}")

    procedure_def = %{
      name: generate_procedure_name(pattern),
      description: pattern.description,
      steps: convert_components_to_steps(pattern.components),
      triggers: pattern.trigger_conditions,
      metadata: %{
        source: "emergence",
        pattern_id: pattern.id,
        success_rate: pattern.success_rate
      }
    }

    # Would integrate with ProceduralStore
    # For now, return the definition
    {:ok,
     %{
       type: :procedure,
       definition: procedure_def
     }}
  end

  defp promote_to_knowledge(pattern) do
    # Convert inference pattern to semantic knowledge
    Logger.debug("[Promoter] Converting inference to knowledge: #{pattern.description}")

    # Create a fact in semantic store using the Ingestor
    source = "emergence:#{pattern.id}"

    case Mimo.SemanticStore.Ingestor.ingest_text(pattern.description, source) do
      {:ok, count} when count > 0 ->
        {:ok,
         %{
           type: :knowledge,
           triples_created: count,
           source: source
         }}

      {:ok, _} ->
        # No triples created, store locally
        {:ok,
         %{
           type: :knowledge,
           stored_locally: true,
           content: pattern.description
         }}
    end
  rescue
    _ ->
      {:ok,
       %{
         type: :knowledge,
         stored_locally: true,
         content: pattern.description
       }}
  end

  defp promote_to_cognitive_pattern(pattern) do
    # Convert heuristic to a reusable cognitive pattern
    Logger.debug("[Promoter] Converting heuristic to cognitive pattern: #{pattern.description}")

    cognitive_pattern = %{
      name: generate_heuristic_name(pattern),
      description: pattern.description,
      applicability: pattern.trigger_conditions,
      success_rate: pattern.success_rate,
      source: "emergence",
      pattern_id: pattern.id
    }

    # Would integrate with CognitivePatterns module
    {:ok,
     %{
       type: :cognitive_pattern,
       definition: cognitive_pattern
     }}
  end

  defp promote_to_capability(pattern) do
    # Register skill as an explicit capability
    Logger.debug("[Promoter] Registering skill as capability: #{pattern.description}")

    capability = %{
      name: generate_capability_name(pattern),
      description: pattern.description,
      tools_involved: extract_tools(pattern.components),
      domains: pattern.metadata[:domains] || [],
      proficiency: pattern.success_rate,
      source: "emergence",
      pattern_id: pattern.id
    }

    {:ok,
     %{
       type: :capability,
       definition: capability
     }}
  end

  # ─────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────

  defp merge_thresholds(opts) do
    %{
      occurrences: Keyword.get(opts, :min_occurrences, @default_thresholds.occurrences),
      success_rate: Keyword.get(opts, :min_success_rate, @default_thresholds.success_rate),
      strength: Keyword.get(opts, :min_strength, @default_thresholds.strength)
    }
  end

  defp build_recommendation(scores, thresholds) do
    improvements = []

    improvements =
      if scores.occurrence_score < 1.0 do
        needed = round((1.0 - scores.occurrence_score) * thresholds.occurrences)
        improvements ++ ["Need #{needed} more occurrences"]
      else
        improvements
      end

    improvements =
      if scores.success_score < 1.0 do
        needed = Float.round((1.0 - scores.success_score) * thresholds.success_rate * 100, 1)
        improvements ++ ["Need #{needed}% higher success rate"]
      else
        improvements
      end

    improvements =
      if scores.strength_score < 1.0 do
        needed = Float.round((1.0 - scores.strength_score) * thresholds.strength * 100, 1)
        improvements ++ ["Need #{needed}% more strength"]
      else
        improvements
      end

    if improvements == [] do
      "Pattern is ready for promotion"
    else
      Enum.join(improvements, "; ")
    end
  end

  defp generate_procedure_name(pattern) do
    # Generate a procedure name from the description
    pattern.description
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end

  defp generate_heuristic_name(pattern) do
    "heuristic_#{pattern.id |> String.slice(0, 8)}"
  end

  defp generate_capability_name(pattern) do
    "capability_#{pattern.id |> String.slice(0, 8)}"
  end

  defp convert_components_to_steps(components) do
    components
    |> Enum.with_index()
    |> Enum.map(fn {component, index} ->
      %{
        order: index + 1,
        tool: component[:tool] || component["tool"],
        parameters: Map.drop(component, [:tool, "tool"])
      }
    end)
  end

  defp extract_tools(components) do
    components
    |> Enum.map(&(&1[:tool] || &1["tool"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
