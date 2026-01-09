defmodule Mimo.Brain.Reflector.ConfidenceEstimator do
  @moduledoc """
  Estimates epistemic uncertainty in outputs.

  Part of SPEC-043: Reflective Intelligence System.

  Combines multiple signals to estimate confidence:
  - Memory grounding: How well is the output backed by stored memories?
  - Source reliability: Quality of the knowledge sources used
  - Reasoning validity: Is the reasoning chain sound?
  - Query alignment: Does the output actually address the query?

  ## Confidence Levels

  | Level     | Score Range | Communication Style              |
  |-----------|-------------|----------------------------------|
  | very_high | 0.9 - 1.0   | State directly, no qualifiers    |
  | high      | 0.75 - 0.89 | Minimal qualification needed     |
  | medium    | 0.5 - 0.74  | "I believe...", invite verify    |
  | low       | 0.25 - 0.49 | "I'm not certain...", recommend  |
  | very_low  | 0.0 - 0.24  | Acknowledge limitation, offer    |

  ## Example

      result = ConfidenceEstimator.estimate(output, context)
      # => %{
      #   score: 0.78,
      #   level: :high,
      #   signals: %{memory: 0.8, sources: 0.7, reasoning: 0.85, alignment: 0.76},
      #   calibrated: true
      # }
  """

  @type confidence_level :: :very_high | :high | :medium | :low | :very_low

  @type confidence_result :: %{
          score: float(),
          level: confidence_level(),
          signals: %{
            memory_grounding: float(),
            source_reliability: float(),
            reasoning_validity: float(),
            query_alignment: float()
          },
          calibrated: boolean(),
          explanation: String.t()
        }

  # Confidence level thresholds (reserved for future use)
  # @confidence_levels %{
  #   very_high: {0.9, 1.0},
  #   high: {0.75, 0.89},
  #   medium: {0.5, 0.74},
  #   low: {0.25, 0.49},
  #   very_low: {0.0, 0.24}
  # }

  alias Mimo.Cognitive.FeedbackLoop

  @signal_weights %{
    memory_grounding: 0.30,
    source_reliability: 0.25,
    reasoning_validity: 0.25,
    query_alignment: 0.20
  }

  @doc """
  Estimate confidence for an output given context.

  ## Parameters

  - `output` - The generated output to assess
  - `context` - Map containing:
    - `:query` - Original query
    - `:memories` - Retrieved memories (with similarity scores)
    - `:reasoning_steps` - Reasoning chain if available
    - `:tool_results` - Tool outputs used

  ## Options

  - `:apply_calibration` - Apply historical calibration (default: true)
  - `:fast_mode` - Skip expensive checks (default: false)
  """
  @spec estimate(String.t(), map(), keyword()) :: confidence_result()
  def estimate(output, context, opts \\ []) do
    apply_calibration = Keyword.get(opts, :apply_calibration, true)
    fast_mode = Keyword.get(opts, :fast_mode, false)

    # Calculate individual signals
    signals =
      if fast_mode do
        %{
          memory_grounding: quick_memory_signal(context),
          # Neutral in fast mode
          source_reliability: 0.5,
          reasoning_validity: 0.5,
          query_alignment: quick_alignment_signal(output, context)
        }
      else
        %{
          memory_grounding: memory_grounding_signal(output, context),
          source_reliability: source_reliability_signal(context),
          reasoning_validity: reasoning_validity_signal(output, context),
          query_alignment: query_alignment_signal(output, context)
        }
      end

    # Calculate weighted score
    raw_score = weighted_average(signals)

    # Apply calibration if enabled
    {final_score, calibrated} =
      if apply_calibration do
        {apply_calibration(raw_score, context), true}
      else
        {raw_score, false}
      end

    # Categorize into levels
    level = categorize(final_score)

    # Generate explanation
    explanation = generate_explanation(level, signals)

    %{
      score: Float.round(final_score, 3),
      level: level,
      signals: signals |> Enum.map(fn {k, v} -> {k, Float.round(v, 3)} end) |> Map.new(),
      calibrated: calibrated,
      explanation: explanation
    }
  end

  @doc """
  Quick confidence check without full assessment.
  """
  @spec quick_estimate(String.t(), map()) :: confidence_level()
  def quick_estimate(_output, context) do
    memories = context[:memories] || []

    cond do
      length(memories) >= 5 -> :high
      length(memories) >= 2 -> :medium
      memories != [] -> :low
      true -> :very_low
    end
  end

  @doc """
  Get the confidence level for a numeric score.
  """
  @spec categorize(float()) :: confidence_level()
  def categorize(score) when is_float(score) or is_integer(score) do
    score = if is_integer(score), do: score / 1.0, else: score

    cond do
      score >= 0.9 -> :very_high
      score >= 0.75 -> :high
      score >= 0.5 -> :medium
      score >= 0.25 -> :low
      true -> :very_low
    end
  end

  @doc """
  Get recommended language qualifiers for a confidence level.
  """
  @spec language_qualifier(confidence_level()) :: String.t() | nil
  def language_qualifier(level) do
    case level do
      # No qualifier needed
      :very_high -> nil
      :high -> "From what I understand"
      :medium -> "I believe"
      :low -> "I'm not certain, but"
      :very_low -> "I don't have reliable information about this, but"
    end
  end

  @doc """
  Check if confidence is sufficient for direct assertion.
  """
  @spec sufficient_for_assertion?(float()) :: boolean()
  def sufficient_for_assertion?(score) do
    score >= 0.75
  end

  defp memory_grounding_signal(output, context) do
    memories = context[:memories] || []

    if memories == [] do
      # No memories = low grounding
      0.2
    else
      # Check overlap between output content and memory content
      output_words = extract_key_terms(output)

      memory_coverage =
        memories
        |> Enum.map(fn m ->
          content = m[:content] || m["content"] || ""
          similarity = m[:similarity] || m["similarity"] || 0.5
          memory_words = extract_key_terms(content)

          overlap =
            MapSet.intersection(
              MapSet.new(output_words),
              MapSet.new(memory_words)
            )
            |> MapSet.size()

          # Combine word overlap with semantic similarity
          overlap_ratio = overlap / max(length(output_words), 1)
          (overlap_ratio + similarity) / 2
        end)
        |> Enum.max(fn -> 0.0 end)

      # More memories = higher potential grounding
      memory_count_factor =
        cond do
          length(memories) >= 5 -> 1.0
          length(memories) >= 3 -> 0.9
          memories != [] -> 0.7
          true -> 0.3
        end

      memory_coverage * memory_count_factor
    end
  end

  defp quick_memory_signal(context) do
    memories = context[:memories] || []

    cond do
      length(memories) >= 5 -> 0.9
      length(memories) >= 3 -> 0.7
      memories != [] -> 0.5
      true -> 0.2
    end
  end

  defp source_reliability_signal(context) do
    memories = context[:memories] || []
    tool_results = context[:tool_results] || []

    # Memory reliability based on importance and recency
    memory_reliability =
      if memories == [] do
        0.0
      else
        memories
        |> Enum.map(fn m ->
          importance = m[:importance] || m["importance"] || 0.5
          # Higher importance = more reliable source
          importance
        end)
        |> Enum.sum()
        |> Kernel./(length(memories))
      end

    # Tool results are generally reliable (deterministic)
    tool_reliability = if tool_results != [], do: 0.9, else: 0.0

    # Combine based on what's available
    cond do
      memories != [] and tool_results != [] ->
        memory_reliability * 0.4 + tool_reliability * 0.6

      tool_results != [] ->
        tool_reliability

      memories != [] ->
        # Slight penalty for memory-only
        memory_reliability * 0.8

      true ->
        # No sources = low reliability
        0.3
    end
  end

  defp reasoning_validity_signal(output, context) do
    reasoning_steps = context[:reasoning_steps] || []

    if reasoning_steps == [] do
      # No explicit reasoning chain - check output for reasoning markers
      check_implicit_reasoning(output)
    else
      # Check if reasoning chain is sound
      check_reasoning_chain(reasoning_steps, output)
    end
  end

  defp check_implicit_reasoning(output) do
    # Look for reasoning indicators in output
    reasoning_markers = [
      ~r/\bbecause\b/i,
      ~r/\btherefore\b/i,
      ~r/\bsince\b/i,
      ~r/\bthus\b/i,
      ~r/\bgiven that\b/i,
      ~r/\bconsequently\b/i
    ]

    marker_count = Enum.count(reasoning_markers, &String.match?(output, &1))

    # More reasoning markers = slightly higher validity
    min(0.7, 0.4 + marker_count * 0.05)
  end

  defp check_reasoning_chain(steps, output) do
    if steps == [] do
      0.5
    else
      # Check for logical flow in steps
      step_contents =
        Enum.map(steps, fn s ->
          cond do
            is_binary(s) -> s
            is_map(s) -> s[:content] || s["content"] || inspect(s)
            true -> inspect(s)
          end
        end)

      # Check each step connects to the next
      connection_scores =
        step_contents
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] ->
          a_words = extract_key_terms(a)
          b_words = extract_key_terms(b)
          overlap = MapSet.intersection(MapSet.new(a_words), MapSet.new(b_words)) |> MapSet.size()
          if overlap > 0, do: 1.0, else: 0.5
        end)

      # Check final step connects to output
      final_step = List.last(step_contents)
      final_words = extract_key_terms(final_step)
      output_words = extract_key_terms(output)

      final_overlap =
        MapSet.intersection(MapSet.new(final_words), MapSet.new(output_words)) |> MapSet.size()

      final_connection = if final_overlap > 1, do: 1.0, else: 0.5

      all_scores = connection_scores ++ [final_connection]

      Enum.sum(all_scores) / length(all_scores)
    end
  end

  defp query_alignment_signal(output, context) do
    query = context[:query] || ""

    if query == "" do
      0.5
    else
      calculate_query_alignment(output, query)
    end
  end

  defp calculate_query_alignment(output, query) do
    query_words = extract_key_terms(query)

    if query_words == [] do
      0.5
    else
      output_words = extract_key_terms(output)
      coverage_ratio = calculate_coverage_ratio(query_words, output_words)

      question_type = detect_question_type(query)
      answer_type_match = check_answer_type(output, question_type)

      coverage_ratio * 0.6 + answer_type_match * 0.4
    end
  end

  defp calculate_coverage_ratio(query_words, output_words) do
    covered =
      Enum.count(query_words, fn qw ->
        Enum.any?(output_words, fn ow ->
          String.contains?(ow, qw) or String.contains?(qw, ow)
        end)
      end)

    covered / length(query_words)
  end

  defp quick_alignment_signal(output, context) do
    query = context[:query] || ""

    if query == "" do
      0.5
    else
      # Quick word overlap check
      query_lower = String.downcase(query)
      output_lower = String.downcase(output)

      query_words = String.split(query_lower) |> Enum.take(5)
      matches = Enum.count(query_words, &String.contains?(output_lower, &1))

      matches / max(length(query_words), 1)
    end
  end

  defp apply_calibration(score, _context) do
    # Phase 3 L5: Historical data-based confidence calibration
    # Adjusts raw confidence based on actual prediction accuracy
    try do
      # Get prediction accuracy from FeedbackLoop
      prediction_accuracy = FeedbackLoop.prediction_accuracy()

      # Only apply calibration if we have enough data
      if prediction_accuracy > 0 do
        # If predictions are historically overconfident, reduce new scores
        # If historically underconfident, increase new scores
        # Use 0.5 as the neutral point
        calibration_factor =
          cond do
            # Historical accuracy significantly lower than typical confidence
            # → predictions have been overconfident, reduce score
            prediction_accuracy < 0.4 -> 0.85
            prediction_accuracy < 0.5 -> 0.90
            prediction_accuracy < 0.6 -> 0.95
            # Accuracy matches confidence well → no adjustment
            prediction_accuracy < 0.75 -> 1.0
            # Historical accuracy higher than expected → can be slightly more confident
            prediction_accuracy >= 0.75 -> min(1.05, 1.0 + (prediction_accuracy - 0.75) * 0.2)
            true -> 1.0
          end

        # Apply calibration but never exceed 1.0 or go below 0.1
        calibrated = score * calibration_factor
        Float.round(min(1.0, max(0.1, calibrated)), 3)
      else
        # No historical data - apply conservative default (slight reduction for high scores)
        if score > 0.8, do: score * 0.95, else: score
      end
    rescue
      _ ->
        # Fallback to simple calibration if FeedbackLoop unavailable
        if score > 0.8, do: score * 0.95, else: score
    catch
      _, _ ->
        if score > 0.8, do: score * 0.95, else: score
    end
  end

  defp weighted_average(signals) do
    @signal_weights
    |> Enum.map(fn {key, weight} ->
      score = Map.get(signals, key, 0.5)
      score * weight
    end)
    |> Enum.sum()
  end

  defp extract_key_terms(text) when is_binary(text) do
    common_words = ~w(the a an is are was were be been being have has had
      do does did will would could should may might must can
      this that these those what when where which who how
      for from with about into through and but or not
      to of in on at by it its i we you they them their)

    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(fn x -> String.length(x) < 3 or x in common_words end)
    |> Enum.uniq()
  end

  defp detect_question_type(query) do
    query_lower = String.downcase(query)

    cond do
      String.match?(query_lower, ~r/^(what|which)\b/) -> :what
      String.match?(query_lower, ~r/^how\b/) -> :how
      String.match?(query_lower, ~r/^why\b/) -> :why
      String.match?(query_lower, ~r/^(can|could|is|are|does|do|will)\b/) -> :yes_no
      String.match?(query_lower, ~r/^when\b/) -> :when
      String.match?(query_lower, ~r/^where\b/) -> :where
      String.match?(query_lower, ~r/^who\b/) -> :who
      true -> :unknown
    end
  end

  defp check_answer_type(output, question_type) do
    case question_type do
      :how ->
        # How questions should have steps or process
        if String.match?(output, ~r/(first|then|next|finally|\d+\.|\*|-)/i), do: 1.0, else: 0.5

      :why ->
        # Why questions should have causal language
        if String.match?(output, ~r/(because|since|due to|as a result|therefore)/i),
          do: 1.0,
          else: 0.5

      :yes_no ->
        # Yes/no should have affirmative/negative
        if String.match?(output, ~r/^(yes|no|it is|it isn't|it's not|it does|it doesn't)/i),
          do: 1.0,
          else: 0.5

      :when ->
        # When questions should have temporal info
        if String.match?(output, ~r/(\d{4}|\bwhen\b|\btime\b|\bdate\b|ago|before|after)/i),
          do: 1.0,
          else: 0.5

      :where ->
        # Where questions should have location
        if String.match?(output, ~r/(in |at |on |location|place|where|file|path|directory)/i),
          do: 1.0,
          else: 0.5

      _ ->
        # Default for what/which/who/unknown
        0.7
    end
  end

  defp generate_explanation(level, signals) do
    weak_signals =
      signals
      |> Enum.filter(fn {_k, v} -> v < 0.5 end)
      |> Enum.map(fn {k, _v} ->
        case k do
          :memory_grounding -> "limited memory grounding"
          :source_reliability -> "uncertain source reliability"
          :reasoning_validity -> "reasoning chain concerns"
          :query_alignment -> "potential query misalignment"
        end
      end)

    case level do
      :very_high ->
        "High confidence based on strong evidence across all signals."

      :high ->
        "Good confidence with solid grounding in stored knowledge."

      :medium ->
        if weak_signals == [] do
          "Moderate confidence - verification recommended."
        else
          "Moderate confidence. Concerns: #{Enum.join(weak_signals, ", ")}."
        end

      :low ->
        "Low confidence. Issues: #{Enum.join(weak_signals, ", ")}. Verification strongly recommended."

      :very_low ->
        "Very low confidence. Lacks sufficient grounding. Consider this speculative."
    end
  end
end
