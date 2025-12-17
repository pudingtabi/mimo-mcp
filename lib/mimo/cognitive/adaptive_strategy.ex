defmodule Mimo.Cognitive.AdaptiveStrategy do
  @moduledoc """
  SPEC-082-A: Adaptive Strategy Selection

  Dynamic strategy selection based on step evaluation within interleaved thinking.
  Analyzes each reasoning step's results to recommend the best next action.

  ## Strategy Mapping

  | Condition | Action | Strategy Origin |
  |-----------|--------|-----------------|
  | Low confidence | :branch | ToT |
  | Verification failed | :reflect | Reflexion |
  | Knowledge gap | :use_tool | ReAct |
  | Contradiction | :backtrack | ToT |
  | All good | :continue | CoT |

  ## Usage

      step_result = InterleavedThinking.think(session_id, thought)
      {:ok, action, reason} = AdaptiveStrategy.recommend_next(step_result)
  """

  require Logger

  @type action ::
          :continue
          | :branch
          | :backtrack
          | :reflect
          | :use_tool
          | :verify_claim
          | :gather_context

  @type recommendation :: {:ok, action(), String.t()} | {:error, term()}

  # Thresholds for strategy switching
  @low_confidence_threshold 0.5
  @very_low_confidence_threshold 0.3
  @declining_trend_threshold 3

  @doc """
  Recommend the next action based on step evaluation results.

  Analyzes confidence, verification status, and accumulated context
  to determine the best strategy to apply for the next step.
  """
  @spec recommend_next(map()) :: recommendation()
  def recommend_next(step_result) when is_map(step_result) do
    # Extract key signals
    confidence = get_in(step_result, [:confidence, :score]) || 0.5
    confidence_level = get_in(step_result, [:confidence, :level]) || :medium
    verification_status = get_in(step_result, [:verification, :status]) || :unverified
    contradictions = get_in(step_result, [:verification, :contradictions]) || []
    gaps = get_in(step_result, [:verification, :gaps]) || []
    accumulated = step_result[:accumulated_context] || %{}
    evaluation_quality = get_in(step_result, [:evaluation, :quality]) || :good

    # Decision logic (priority order)
    cond do
      # Critical: Contradiction detected → backtrack immediately
      contradictions != [] and length(contradictions) > 0 ->
        {:ok, :backtrack,
         "🔙 Contradiction detected: #{inspect(Enum.take(contradictions, 1))} - try different approach"}

      # Verification explicitly failed → reflect on approach
      verification_status == :failed ->
        {:ok, :reflect, "🔄 Verification failed - reflect on reasoning approach"}

      # Very low confidence → definitely branch
      confidence < @very_low_confidence_threshold ->
        {:ok, :branch,
         "🌳 Very low confidence (#{Float.round(confidence, 2)}) - explore alternatives"}

      # Knowledge gaps that need external info
      has_actionable_gaps?(gaps) ->
        {:ok, :use_tool, "🔧 Knowledge gap detected - gather external information"}

      # Low confidence → consider branching
      confidence < @low_confidence_threshold or confidence_level == :low ->
        {:ok, :branch,
         "🌳 Low confidence (#{Float.round(confidence, 2)}) - consider exploring alternatives"}

      # Declining confidence trend → reflect before continuing
      declining_trend?(accumulated) ->
        {:ok, :reflect,
         "📉 Confidence declining over #{@declining_trend_threshold}+ steps - reflect"}

      # Bad evaluation quality → need to improve reasoning
      evaluation_quality == :bad ->
        {:ok, :reflect, "⚠️ Reasoning quality poor - reflect and improve approach"}

      # Unverified claims that should be checked
      has_unverified_claims?(step_result) ->
        {:ok, :verify_claim, "✓ Unverified claims detected - verify before proceeding"}

      # Default: Continue linear reasoning (CoT)
      true ->
        {:ok, :continue,
         "✅ On track (confidence: #{Float.round(confidence, 2)}) - continue reasoning"}
    end
  end

  def recommend_next(_), do: {:ok, :continue, "No step context - continue"}

  @doc """
  Get a human-readable summary of the recommended action.
  """
  @spec action_guidance(action()) :: String.t()
  def action_guidance(:continue),
    do: "Continue with the next reasoning step using `reason operation=interleaved_think`"

  def action_guidance(:branch),
    do: "Create an alternative approach using `reason operation=branch`"

  def action_guidance(:backtrack),
    do: "Abandon current path using `reason operation=backtrack`"

  def action_guidance(:reflect),
    do: "Analyze what went wrong using `reason operation=reflect`"

  def action_guidance(:use_tool),
    do: "Gather information using file/terminal/code/memory tools"

  def action_guidance(:verify_claim),
    do: "Verify specific claims using `reason operation=verify_claim`"

  def action_guidance(:gather_context),
    do: "Get more context using `meta operation=prepare_context`"

  # Private helpers

  defp has_actionable_gaps?(gaps) when is_list(gaps) do
    # Filter out generic/timeout gaps
    actionable =
      Enum.reject(gaps, fn gap ->
        is_binary(gap) and
          (String.contains?(gap, "timed out") or
             String.contains?(gap, "No specific claims"))
      end)

    length(actionable) > 0
  end

  defp has_actionable_gaps?(_), do: false

  defp declining_trend?(accumulated) when is_map(accumulated) do
    trend = Map.get(accumulated, :confidence_trend, "stable")
    steps = Map.get(accumulated, :steps_completed, 0)

    trend == "declining" and steps >= @declining_trend_threshold
  end

  defp declining_trend?(_), do: false

  defp has_unverified_claims?(step_result) do
    verification = step_result[:verification] || %{}
    status = Map.get(verification, :status, :unverified)
    verified_count = get_in(step_result, [:accumulated_context, :verified_facts_count]) || 0
    step_number = step_result[:step_number] || 1

    # Flag if we're several steps in with no verified facts
    status == :unverified and step_number > 2 and verified_count == 0
  end
end
