defmodule Mimo.Cognitive.Calibration do
  @moduledoc """
  SPEC-062: Confidence Calibration Tracker.

  Tracks confidence claims vs actual outcomes to measure and improve
  AI confidence calibration. Uses Brier scoring to detect:
  - Overconfidence (high confidence + wrong answers)
  - Underconfidence (low confidence + correct answers)
  - Well-calibrated predictions

  ## Calibration Quality

  Brier Score interpretation:
  - 0.00-0.10: Excellent calibration
  - 0.10-0.20: Good calibration  
  - 0.20-0.30: Acceptable calibration
  - 0.30+: Poor calibration (needs improvement)

  ## Usage

      # Log a confidence claim before answering
      Calibration.log_claim("capital of France", 95, "Paris")

      # After verification, log the outcome
      Calibration.log_outcome("capital of France", true)

      # Get calibration statistics
      {:ok, stats} = Calibration.brier_score()

  ## Integration with Memory

  Claims are stored in memory for cross-session tracking and
  pattern detection.
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Brain.VerificationTracker

  @type claim :: %{
          topic: String.t(),
          confidence: float(),
          answer: term(),
          timestamp: DateTime.t()
        }

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Log a confidence claim for a topic/answer.

  ## Parameters

  - topic: What the claim is about
  - confidence: Confidence percentage (0-100)
  - answer: The claimed answer

  ## Example

      Calibration.log_claim("What is 2+2?", 95, "4")
  """
  @spec log_claim(String.t(), number(), term()) :: {:ok, map()} | {:error, term()}
  def log_claim(topic, confidence, answer) when is_number(confidence) do
    normalized_confidence = normalize_confidence(confidence)

    # Store in memory for cross-session tracking
    content = "Confidence: #{normalized_confidence}% on '#{topic}' → #{inspect(answer)}"

    case Memory.store(%{
           content: content,
           category: :observation,
           importance: 0.6,
           metadata: %{
             type: "calibration_claim",
             confidence: normalized_confidence,
             topic: topic,
             answer: answer,
             outcome: nil,
             timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
           }
         }) do
      {:ok, engram} ->
        # Also record in VerificationTracker for real-time stats
        VerificationTracker.record_claim(topic, %{
          claimed: answer,
          confidence: normalized_confidence / 100,
          method: :genuine
        })

        {:ok,
         %{
           status: "claim_logged",
           memory_id: engram.id,
           topic: topic,
           confidence: normalized_confidence,
           answer: answer
         }}

      {:error, reason} ->
        Logger.warning("[Calibration] Failed to store claim: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Log the outcome for a previously made claim.

  ## Parameters

  - topic: The topic of the original claim
  - correct?: Whether the answer was correct

  ## Example

      Calibration.log_outcome("What is 2+2?", true)
  """
  @spec log_outcome(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def log_outcome(topic, correct?) when is_boolean(correct?) do
    # Find the original claim in memory
    case Memory.search("Confidence: % on '#{topic}'", limit: 1, category: :observation) do
      {:ok, [claim | _]} ->
        # Update the metadata with outcome
        update_claim_outcome(claim, correct?)

      {:ok, []} ->
        {:error, "No claim found for topic: #{topic}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculate Brier score for confidence calibration.

  Returns the average Brier score and interpretation.
  """
  @spec brier_score() :: {:ok, map()} | {:error, term()}
  def brier_score do
    claims = get_claims_with_outcomes()

    if claims == [] do
      {:error, "No calibration data available"}
    else
      calculate_brier(claims)
    end
  end

  @doc """
  Get calibration statistics summary.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    # Get from VerificationTracker
    tracker_stats = VerificationTracker.stats()

    # Get memory-based claims
    claims = get_claims_with_outcomes()
    pending_claims = get_pending_claims()

    {:ok,
     %{
       total_claims: tracker_stats.total_claims,
       claims_with_outcomes: length(claims),
       pending_outcomes: length(pending_claims),
       overconfidence_detected: tracker_stats.overconfidence_detected,
       calibration: format_calibration(claims)
     }}
  end

  @doc """
  Detect overconfidence patterns (high confidence + wrong).
  """
  @spec overconfidence_analysis() :: {:ok, list(map())}
  def overconfidence_analysis do
    # Delegate to VerificationTracker
    patterns = VerificationTracker.detect_overconfidence(brier_threshold: 0.3)

    analysis =
      if length(patterns) > 0 do
        %{
          detected: true,
          pattern_count: length(patterns),
          patterns: patterns,
          recommendation:
            "Consider using verify tool before claiming high confidence on similar topics"
        }
      else
        %{
          detected: false,
          pattern_count: 0,
          patterns: [],
          recommendation: "Confidence calibration appears healthy"
        }
      end

    {:ok, analysis}
  end

  @doc """
  Get calibration breakdown by confidence bucket.

  Returns accuracy for each confidence range (0-20%, 20-40%, etc.)
  """
  @spec calibration_curve() :: {:ok, list(map())}
  def calibration_curve do
    claims = get_claims_with_outcomes()

    buckets =
      claims
      |> Enum.group_by(fn %{confidence: c} ->
        cond do
          c < 20 -> "0-20%"
          c < 40 -> "20-40%"
          c < 60 -> "40-60%"
          c < 80 -> "60-80%"
          true -> "80-100%"
        end
      end)
      |> Enum.map(fn {bucket, bucket_claims} ->
        correct_count = Enum.count(bucket_claims, & &1.outcome)
        total = length(bucket_claims)
        actual_accuracy = if total > 0, do: correct_count / total, else: 0.0

        # Expected accuracy is the midpoint of the bucket
        expected_accuracy =
          case bucket do
            "0-20%" -> 0.10
            "20-40%" -> 0.30
            "40-60%" -> 0.50
            "60-80%" -> 0.70
            "80-100%" -> 0.90
          end

        %{
          bucket: bucket,
          claims_count: total,
          actual_accuracy: Float.round(actual_accuracy, 3),
          expected_accuracy: expected_accuracy,
          gap: Float.round(actual_accuracy - expected_accuracy, 3),
          well_calibrated: abs(actual_accuracy - expected_accuracy) < 0.15
        }
      end)
      |> Enum.sort_by(& &1.bucket)

    {:ok, buckets}
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  defp normalize_confidence(c) when c > 1 and c <= 100, do: c
  defp normalize_confidence(c) when c >= 0 and c <= 1, do: c * 100
  defp normalize_confidence(c) when c < 0, do: 0
  defp normalize_confidence(c) when c > 100, do: 100
  defp normalize_confidence(_), do: 50

  defp update_claim_outcome(claim, correct?) do
    # Update metadata with outcome
    metadata = Map.get(claim, :metadata, %{}) || %{}
    _updated_metadata = Map.put(metadata, "outcome", correct?)

    # Memory doesn't have update_metadata, so we store a follow-up memory
    outcome_content =
      "Calibration outcome for '#{metadata["topic"] || "unknown"}': #{if correct?, do: "CORRECT", else: "INCORRECT"}"

    Memory.store(%{
      content: outcome_content,
      category: :observation,
      importance: 0.5,
      metadata: %{
        type: "calibration_outcome",
        claim_id: claim.id,
        outcome: correct?,
        original_confidence: metadata["confidence"]
      }
    })

    # Record in VerificationTracker for Brier calculation
    if metadata["confidence"] do
      VerificationTracker.record_verification(:calibration, %{
        claimed: metadata["answer"],
        actual: if(correct?, do: metadata["answer"], else: "different"),
        verified: correct?,
        confidence: metadata["confidence"] / 100
      })
    end

    {:ok,
     %{
       status: "outcome_logged",
       claim_id: claim.id,
       topic: metadata["topic"],
       original_confidence: metadata["confidence"],
       outcome: correct?
     }}
  end

  defp get_claims_with_outcomes do
    # Get calibration claims from memory
    case Memory.search("Calibration outcome", limit: 100, category: :observation) do
      {:ok, outcomes} ->
        Enum.map(outcomes, fn outcome ->
          metadata = outcome.metadata || %{}

          %{
            confidence: metadata["original_confidence"] || 50,
            outcome: metadata["outcome"] == true
          }
        end)
        |> Enum.filter(&(&1.confidence != nil))

      {:error, _} ->
        []
    end
  end

  defp get_pending_claims do
    case Memory.search("Confidence:", limit: 50, category: :observation) do
      {:ok, claims} ->
        Enum.filter(claims, fn claim ->
          metadata = claim.metadata || %{}
          metadata["type"] == "calibration_claim" and metadata["outcome"] == nil
        end)

      {:error, _} ->
        []
    end
  end

  defp calculate_brier(claims) do
    brier_scores =
      claims
      |> Enum.map(fn %{confidence: c, outcome: o} ->
        prob = c / 100
        actual = if o, do: 1.0, else: 0.0
        :math.pow(prob - actual, 2)
      end)

    avg_brier = Enum.sum(brier_scores) / length(brier_scores)

    {:ok,
     %{
       brier_score: Float.round(avg_brier, 4),
       quality: quality_label(avg_brier),
       sample_size: length(claims),
       interpretation: interpret_brier(avg_brier),
       note: "Brier score: 0=perfect, 0.25=random guessing, 1=always wrong"
     }}
  end

  defp quality_label(s) when s < 0.10, do: "excellent"
  defp quality_label(s) when s < 0.20, do: "good"
  defp quality_label(s) when s < 0.30, do: "acceptable"
  defp quality_label(_), do: "poor"

  defp interpret_brier(s) do
    cond do
      s < 0.10 ->
        "Excellent calibration. Confidence levels accurately reflect actual accuracy."

      s < 0.20 ->
        "Good calibration. Minor adjustments could improve accuracy."

      s < 0.30 ->
        "Acceptable calibration. Consider using verification tools more often."

      true ->
        "Poor calibration. Strongly recommend using verification tools before claiming high confidence."
    end
  end

  defp format_calibration([]) do
    %{status: "no_data", message: "Log some claims and outcomes to see calibration stats"}
  end

  defp format_calibration(claims) do
    case calculate_brier(claims) do
      {:ok, brier_data} -> brier_data
      _ -> %{status: "calculation_error"}
    end
  end
end
