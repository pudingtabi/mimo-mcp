defmodule Mimo.Brain.DecayScorer do
  @moduledoc """
  Calculates decay scores for memories using exponential decay formula.

  The effective score determines memory relevance and whether it should
  be forgotten during cleanup cycles.

  ## Formula

      score = importance × recency_factor × access_factor

  Where:
  - `recency_factor = e^(-λ × active_days)` - Decays over ACTIVE time only
  - `access_factor = 1 + log(1 + access_count) × 0.1` - Boosts frequently accessed
  - `λ = decay_rate` (default 0.1)

  ## Active Days vs Calendar Days

  Decay is based on **active usage days**, not calendar days. This means:
  - If user takes a month vacation, memories DON'T decay during that time
  - Only days where Mimo was actually used count toward decay
  - Protects memories during holidays, breaks, and periods of inactivity

  ## Score Interpretation

  - 0.0 - 0.1: Should be forgotten
  - 0.1 - 0.3: At risk of forgetting
  - 0.3 - 0.7: Healthy memory
  - 0.7 - 1.0: Strong/important memory

  ## Examples

      # Calculate score for a memory
      score = DecayScorer.calculate_score(engram)

      # Check if should be forgotten
      if DecayScorer.should_forget?(engram, 0.1), do: delete(engram)

      # Predict when memory will be forgotten
      days = DecayScorer.predict_forgetting(engram)
  """
  alias ActivityTracker

  @default_decay_rate 0.1
  @default_threshold 0.1

  @doc """
  Calculate the effective score for a memory.

  Uses ACTIVE days (days Mimo was used) instead of calendar days,
  so memories don't decay during vacations or periods of inactivity.

  Returns a value between 0.0 and 1.0.
  """
  @spec calculate_score(map()) :: float()
  def calculate_score(%{} = engram) do
    importance = Map.get(engram, :importance) || 0.5
    access_count = Map.get(engram, :access_count) || 0
    decay_rate = Map.get(engram, :decay_rate) || @default_decay_rate

    last_accessed =
      Map.get(engram, :last_accessed_at) ||
        Map.get(engram, :inserted_at)

    # Use active days instead of calendar days
    # This prevents decay during periods of inactivity
    active_days = get_active_days_since(last_accessed)

    recency_factor = :math.exp(-decay_rate * active_days)
    access_factor = 1 + :math.log(1 + access_count) * 0.1

    # Calculate and clamp to 0-1 range
    score = importance * recency_factor * access_factor
    min(1.0, max(0.0, score))
  end

  @doc """
  Check if a memory should be forgotten based on its score.

  Protected memories are never forgotten regardless of score.
  """
  @spec should_forget?(map(), float()) :: boolean()
  def should_forget?(engram, threshold \\ @default_threshold) do
    # Protected memories are never forgotten
    if Map.get(engram, :protected, false) do
      false
    else
      calculate_score(engram) < threshold
    end
  end

  @doc """
  Predict when a memory will be forgotten (days from now).

  Returns `:never` for protected or very high importance memories.

  ## Parameters

    * `engram` - The memory to analyze
    * `threshold` - Score threshold below which memory is forgotten (default: 0.1)

  ## Returns

    * `float()` - Days until forgotten
    * `:never` - If memory is protected or will never reach threshold
  """
  @spec predict_forgetting(map(), float()) :: float() | :never
  def predict_forgetting(engram, threshold \\ @default_threshold) do
    # Protected memories never forgotten
    if Map.get(engram, :protected, false) do
      :never
    else
      importance = Map.get(engram, :importance) || 0.5
      access_count = Map.get(engram, :access_count) || 0
      decay_rate = Map.get(engram, :decay_rate) || @default_decay_rate

      # Very high importance memories effectively never forgotten
      if importance >= 0.95 do
        :never
      else
        access_factor = 1 + :math.log(1 + access_count) * 0.1

        # Solve: threshold = importance * access_factor * e^(-λ*t)
        # t = -ln(threshold / (importance * access_factor)) / λ
        ratio = threshold / (importance * access_factor)

        cond do
          ratio >= 1 ->
            # Already below threshold
            0.0

          decay_rate == 0 ->
            :never

          true ->
            days = -:math.log(ratio) / decay_rate
            max(0.0, days)
        end
      end
    end
  end

  @doc """
  Calculate scores for a list of memories.
  """
  @spec calculate_scores([map()]) :: [{map(), float()}]
  def calculate_scores(engrams) when is_list(engrams) do
    Enum.map(engrams, fn engram ->
      {engram, calculate_score(engram)}
    end)
  end

  @doc """
  Filter memories that should be forgotten.
  """
  @spec filter_forgettable([map()], float()) :: [map()]
  def filter_forgettable(engrams, threshold \\ @default_threshold) do
    Enum.filter(engrams, &should_forget?(&1, threshold))
  end

  @doc """
  Get decay statistics for a set of memories.
  """
  @spec stats([map()]) :: map()
  def stats(engrams) when is_list(engrams) do
    scores = Enum.map(engrams, &calculate_score/1)

    %{
      count: length(engrams),
      avg_score: safe_avg(scores),
      min_score: Enum.min(scores, fn -> 0.0 end),
      max_score: Enum.max(scores, fn -> 0.0 end),
      at_risk_count: Enum.count(scores, &(&1 < 0.3)),
      forgettable_count: Enum.count(scores, &(&1 < @default_threshold))
    }
  end

  # Get active days since a datetime, with fallback to calendar days
  # if ActivityTracker is not available
  defp get_active_days_since(nil), do: 0.0

  defp get_active_days_since(datetime) do
    try do
      # Try to use ActivityTracker for active-days-based decay
      if Process.whereis(ActivityTracker) do
        Mimo.Brain.ActivityTracker.active_days_since(datetime)
      else
        # Fallback to calendar days if tracker not running
        calculate_age_days(datetime)
      end
    rescue
      _ -> calculate_age_days(datetime)
    end
  end

  defp calculate_age_days(nil), do: 0.0

  defp calculate_age_days(%NaiveDateTime{} = datetime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)
    max(0, diff_seconds / 86_400.0)
  end

  defp calculate_age_days(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)
    max(0, diff_seconds / 86_400.0)
  end

  defp calculate_age_days(_), do: 0.0

  defp safe_avg([]), do: 0.0
  defp safe_avg(list), do: Enum.sum(list) / length(list)
end
