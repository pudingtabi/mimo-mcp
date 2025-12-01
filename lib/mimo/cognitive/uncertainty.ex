defmodule Mimo.Cognitive.Uncertainty do
  @moduledoc """
  Epistemic uncertainty modeling for Mimo.

  Tracks confidence in knowledge and identifies knowledge gaps.
  This is the core data structure for SPEC-024 Phase 1.

  ## Confidence Levels

  - `:high` - Strong evidence from multiple sources (score >= 0.7)
  - `:medium` - Moderate evidence (score >= 0.4, < 0.7)
  - `:low` - Weak evidence (score >= 0.2, < 0.4)
  - `:unknown` - No relevant information found (score < 0.2)

  ## Example

      uncertainty = Uncertainty.new("authentication")
      uncertainty = Uncertainty.assess("How does JWT work?", context)

      case uncertainty.confidence do
        :high -> "I'm confident that..."
        :medium -> "Based on what I understand..."
        :low -> "I'm not entirely certain, but..."
        :unknown -> "I don't have information about this."
      end
  """

  @type confidence_level :: :high | :medium | :low | :unknown

  @type source :: %{
          type: :memory | :code | :library | :graph | :external,
          id: String.t() | nil,
          name: String.t(),
          relevance: float()
        }

  @type t :: %__MODULE__{
          topic: String.t(),
          confidence: confidence_level(),
          score: float(),
          evidence_count: non_neg_integer(),
          last_verified: DateTime.t() | nil,
          sources: [source()],
          decay_factor: float(),
          staleness: float(),
          gap_indicators: [String.t()]
        }

  @enforce_keys [:topic]
  defstruct topic: "",
            confidence: :unknown,
            score: 0.0,
            evidence_count: 0,
            last_verified: nil,
            sources: [],
            decay_factor: 1.0,
            staleness: 0.0,
            gap_indicators: []

  @doc """
  Create a new uncertainty assessment for a topic.
  """
  @spec new(String.t()) :: t()
  def new(topic) when is_binary(topic) do
    %__MODULE__{
      topic: topic,
      confidence: :unknown,
      score: 0.0,
      evidence_count: 0,
      sources: [],
      gap_indicators: []
    }
  end

  @doc """
  Convert a numeric score (0.0-1.0) to a confidence level.

  ## Score Thresholds

  - >= 0.7 → :high
  - >= 0.4 → :medium
  - >= 0.2 → :low
  - < 0.2 → :unknown
  """
  @spec to_confidence_level(float()) :: confidence_level()
  def to_confidence_level(score) when is_float(score) or is_integer(score) do
    cond do
      score >= 0.7 -> :high
      score >= 0.4 -> :medium
      score >= 0.2 -> :low
      true -> :unknown
    end
  end

  @doc """
  Create an uncertainty from assessment results.
  """
  @spec from_assessment(String.t(), float(), [source()], keyword()) :: t()
  def from_assessment(topic, score, sources, opts \\ []) do
    staleness = Keyword.get(opts, :staleness, 0.0)
    gap_indicators = Keyword.get(opts, :gap_indicators, [])

    # Apply staleness penalty
    adjusted_score = score * (1.0 - staleness * 0.3)

    %__MODULE__{
      topic: topic,
      confidence: to_confidence_level(adjusted_score),
      score: adjusted_score,
      evidence_count: length(sources),
      sources: sources,
      last_verified: DateTime.utc_now(),
      decay_factor: calculate_decay_factor(sources),
      staleness: staleness,
      gap_indicators: gap_indicators
    }
  end

  @doc """
  Merge multiple uncertainty assessments into one.
  Uses weighted combination of scores.
  """
  @spec merge([t()]) :: t() | nil
  def merge([]), do: nil
  def merge([single]), do: single

  def merge(assessments) do
    # Weight by evidence count
    total_evidence = Enum.sum(Enum.map(assessments, & &1.evidence_count))

    if total_evidence == 0 do
      # No evidence, return first topic with unknown confidence
      first = hd(assessments)
      %{first | confidence: :unknown, score: 0.0}
    else
      weighted_score =
        assessments
        |> Enum.map(fn a ->
          weight = if total_evidence > 0, do: a.evidence_count / total_evidence, else: 0
          a.score * weight
        end)
        |> Enum.sum()

      all_sources = Enum.flat_map(assessments, & &1.sources)
      all_gaps = Enum.flat_map(assessments, & &1.gap_indicators) |> Enum.uniq()

      topics = Enum.map_join(assessments, ", ", & &1.topic)

      %__MODULE__{
        topic: topics,
        confidence: to_confidence_level(weighted_score),
        score: weighted_score,
        evidence_count: total_evidence,
        sources: all_sources,
        last_verified: DateTime.utc_now(),
        decay_factor: calculate_decay_factor(all_sources),
        staleness: Enum.max(Enum.map(assessments, & &1.staleness)),
        gap_indicators: all_gaps
      }
    end
  end

  @doc """
  Check if the uncertainty indicates a knowledge gap.
  """
  @spec has_gap?(t()) :: boolean()
  def has_gap?(%__MODULE__{confidence: :unknown}), do: true
  def has_gap?(%__MODULE__{confidence: :low}), do: true
  def has_gap?(%__MODULE__{evidence_count: count}) when count < 2, do: true
  def has_gap?(%__MODULE__{gap_indicators: gaps}) when length(gaps) > 0, do: true
  def has_gap?(_), do: false

  @doc """
  Get a human-readable summary of the uncertainty.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = u) do
    confidence_text =
      case u.confidence do
        :high -> "High confidence"
        :medium -> "Moderate confidence"
        :low -> "Low confidence"
        :unknown -> "Unknown"
      end

    source_types =
      u.sources
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.map_join(", ", &to_string/1)

    gap_text =
      if u.gap_indicators != [] do
        "\nGaps: #{Enum.join(u.gap_indicators, ", ")}"
      else
        ""
      end

    """
    Topic: #{u.topic}
    #{confidence_text} (score: #{Float.round(u.score, 2)})
    Evidence: #{u.evidence_count} sources (#{source_types})#{gap_text}
    """
  end

  # Private helpers

  defp calculate_decay_factor(sources) do
    # More diverse sources = slower decay
    type_count =
      sources
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> length()

    base_decay = 1.0
    diversity_bonus = min(type_count * 0.1, 0.3)

    base_decay - diversity_bonus
  end
end
