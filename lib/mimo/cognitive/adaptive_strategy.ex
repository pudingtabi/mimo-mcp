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

  ## SPEC-074-ENHANCED: Threshold Learning

  The module now learns optimal thresholds from historical outcomes.
  Use `learn_from_outcome/3` after each reasoning session to improve accuracy.

  ## Usage

      step_result = InterleavedThinking.think(session_id, thought)
      {:ok, action, reason} = AdaptiveStrategy.recommend_next(step_result)

      # After session completes:
      AdaptiveStrategy.learn_from_outcome(:branch, 0.45, true)
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

  # ETS table for learned thresholds
  @threshold_table :mimo_adaptive_thresholds

  # Default thresholds (used until we have enough data)
  @default_low_confidence 0.5
  @default_very_low_confidence 0.3
  @declining_trend_threshold 3

  # Minimum samples before using learned thresholds
  @min_samples_for_learning 10

  @doc """
  Initialize the ETS table for threshold learning.
  Called during application startup.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@threshold_table) == :undefined do
      :ets.new(@threshold_table, [:named_table, :public, :set])
      Logger.info("[AdaptiveStrategy] Threshold learning table initialized")
    end

    :ok
  end

  @doc """
  Learn from the outcome of a strategy decision.

  Records whether a particular action taken at a given confidence level
  was successful, allowing the system to learn optimal thresholds.

  ## Parameters

  - `action` - The action that was taken (e.g., :branch, :continue)
  - `confidence_at_decision` - The confidence score when the decision was made
  - `success` - Whether the outcome was successful

  ## Example

      AdaptiveStrategy.learn_from_outcome(:branch, 0.45, true)
  """
  @spec learn_from_outcome(action(), float(), boolean()) :: :ok
  def learn_from_outcome(action, confidence_at_decision, success) when is_atom(action) do
    init()
    bucket = confidence_bucket(confidence_at_decision)
    key = {action, bucket}

    case :ets.lookup(@threshold_table, key) do
      [{^key, %{attempts: a, successes: s}}] ->
        new_s = if success, do: s + 1, else: s
        :ets.insert(@threshold_table, {key, %{attempts: a + 1, successes: new_s}})

      [] ->
        s = if success, do: 1, else: 0
        :ets.insert(@threshold_table, {key, %{attempts: 1, successes: s}})
    end

    :ok
  end

  def learn_from_outcome(_, _, _), do: :ok

  @doc """
  Get the learned optimal threshold for a specific action.

  Returns the confidence level that has historically led to the best outcomes
  for this action. Falls back to default if insufficient data.

  ## Example

      # Returns the optimal confidence threshold for branching
      AdaptiveStrategy.get_optimal_threshold(:branch)
  """
  @spec get_optimal_threshold(action()) :: float()
  def get_optimal_threshold(action) do
    init()

    entries =
      @threshold_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{a, _}, _} -> a == action end)
      |> Enum.filter(fn {_, %{attempts: a}} -> a >= @min_samples_for_learning end)

    if entries == [] do
      default_threshold(action)
    else
      # Find the bucket with highest success rate
      best_entry =
        Enum.max_by(entries, fn {{_, bucket}, %{attempts: a, successes: s}} ->
          {s / a, bucket}
        end)

      {{_, best_bucket}, _} = best_entry
      bucket_to_threshold(best_bucket)
    end
  end

  @doc """
  Get learning statistics for all actions.
  """
  @spec learning_stats() :: map()
  def learning_stats do
    init()

    entries = :ets.tab2list(@threshold_table)

    by_action =
      entries
      |> Enum.group_by(fn {{action, _}, _} -> action end)
      |> Enum.map(fn {action, entries} ->
        total_attempts = Enum.sum(Enum.map(entries, fn {_, %{attempts: a}} -> a end))
        total_successes = Enum.sum(Enum.map(entries, fn {_, %{successes: s}} -> s end))

        {action,
         %{
           total_attempts: total_attempts,
           success_rate:
             if(total_attempts > 0, do: Float.round(total_successes / total_attempts, 3), else: 0.0),
           learned_threshold: get_optimal_threshold(action),
           default_threshold: default_threshold(action)
         }}
      end)
      |> Map.new()

    %{
      actions: by_action,
      total_samples: Enum.sum(Enum.map(entries, fn {_, %{attempts: a}} -> a end)),
      using_learned: using_learned_thresholds?()
    }
  end

  # Private: Determine if we have enough data to use learned thresholds
  defp using_learned_thresholds? do
    init()
    total = :ets.info(@threshold_table, :size) || 0
    total >= @min_samples_for_learning
  end

  # Convert confidence to bucket (0.0-0.1, 0.1-0.2, etc.)
  defp confidence_bucket(confidence) when is_number(confidence) do
    (confidence * 10) |> trunc() |> max(0) |> min(9)
  end

  defp confidence_bucket(_), do: 5

  # Convert bucket back to threshold (center of bucket)
  defp bucket_to_threshold(bucket) do
    (bucket + 0.5) / 10
  end

  # Default thresholds per action
  defp default_threshold(:branch), do: @default_low_confidence
  defp default_threshold(:backtrack), do: @default_very_low_confidence
  defp default_threshold(:reflect), do: @default_low_confidence
  defp default_threshold(:use_tool), do: 0.6
  defp default_threshold(:verify_claim), do: 0.7
  defp default_threshold(:continue), do: 0.5
  defp default_threshold(_), do: 0.5

  # Dynamic thresholds (use learned if available)
  defp low_confidence_threshold do
    if using_learned_thresholds?() do
      get_optimal_threshold(:branch)
    else
      @default_low_confidence
    end
  end

  defp very_low_confidence_threshold do
    if using_learned_thresholds?() do
      get_optimal_threshold(:backtrack)
    else
      @default_very_low_confidence
    end
  end

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

    # Get dynamic thresholds (learned or default)
    very_low_thresh = very_low_confidence_threshold()
    low_thresh = low_confidence_threshold()

    # Decision logic (priority order)
    cond do
      # Critical: Contradiction detected → backtrack immediately
      contradictions != [] ->
        {:ok, :backtrack,
         "🔙 Contradiction detected: #{inspect(Enum.take(contradictions, 1))} - try different approach"}

      # Verification explicitly failed → reflect on approach
      verification_status == :failed ->
        {:ok, :reflect, "🔄 Verification failed - reflect on reasoning approach"}

      # Very low confidence → definitely branch
      confidence < very_low_thresh ->
        {:ok, :branch,
         "🌳 Very low confidence (#{Float.round(confidence, 2)}) - explore alternatives"}

      # Knowledge gaps that need external info
      has_actionable_gaps?(gaps) ->
        {:ok, :use_tool, "🔧 Knowledge gap detected - gather external information"}

      # Low confidence → consider branching
      confidence < low_thresh or confidence_level == :low ->
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

    actionable != []
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
