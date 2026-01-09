defmodule Mimo.Cognitive.Amplifier.ConfidenceGapAnalyzer do
  @moduledoc """
  SPEC-092 Phase 2: Detects confidence-verification gaps in reasoning.

  This module identifies when a thought expresses high confidence but lacks
  verified claims - a signal of potential disguised hallucination.

  The gap analysis compares:
  - Linguistic confidence markers (definitely, obviously, clearly, etc.)
  - Presence of justification language (because, since, given, etc.)
  - Claim verification results from ClaimVerifier

  Three risk scenarios detected:
  1. HIGH confidence + LOW verification rate = potential hallucination
  2. HIGH confidence + ZERO claims = "empty verification trap"
  3. Certainty without justification = unsupported assertion
  """

  @type gap_result :: %{
          gap_detected: boolean(),
          risk_level: :none | :low | :medium | :high,
          certainty_detected: boolean(),
          has_justification: boolean(),
          empty_trap: boolean(),
          reason: String.t() | nil
        }

  # Patterns indicating certainty (from ThoughtEvaluator)
  @certainty_patterns ~r/\b(definitely|certainly|obviously|clearly|always|never|must be|has to be|without doubt|undoubtedly|absolutely|unquestionably)\b/i

  # Patterns indicating justification
  @justification_patterns ~r/\b(because|since|given|as|due to|based on|according to|from|supported by|evidence shows|data indicates)\b/i

  # Weaker certainty that's less concerning
  @weak_certainty_patterns ~r/\b(likely|probably|seems|appears|suggests)\b/i

  @doc """
  Analyze a thought for confidence-verification gap.

  Takes the thought text and claim verification result, returns gap analysis.
  """
  @spec analyze(String.t() | nil, map() | nil) :: gap_result()
  def analyze(nil, _claim_verification), do: neutral_result()
  def analyze("", _claim_verification), do: neutral_result()

  def analyze(thought, claim_verification) when is_binary(thought) do
    # Extract certainty signals
    certainty_detected = has_certainty?(thought)
    has_justification = has_justification?(thought)
    weak_certainty = has_weak_certainty?(thought)

    # Extract verification metrics
    {total_claims, verification_rate} = extract_verification_metrics(claim_verification)

    # Analyze for gaps
    analyze_gap(
      certainty_detected,
      has_justification,
      weak_certainty,
      total_claims,
      verification_rate
    )
  end

  @doc """
  Quick check if a thought has potential confidence gap issues.
  """
  @spec has_gap?(String.t(), map() | nil) :: boolean()
  def has_gap?(thought, claim_verification) do
    result = analyze(thought, claim_verification)
    result.gap_detected
  end

  # Private functions

  defp neutral_result do
    %{
      gap_detected: false,
      risk_level: :none,
      certainty_detected: false,
      has_justification: false,
      empty_trap: false,
      reason: nil
    }
  end

  defp has_certainty?(thought) do
    Regex.match?(@certainty_patterns, thought)
  end

  defp has_justification?(thought) do
    Regex.match?(@justification_patterns, thought)
  end

  defp has_weak_certainty?(thought) do
    Regex.match?(@weak_certainty_patterns, thought)
  end

  defp extract_verification_metrics(nil), do: {0, 1.0}
  defp extract_verification_metrics(%{total_claims: 0}), do: {0, 1.0}

  defp extract_verification_metrics(%{total_claims: total, verification_rate: rate}) do
    {total, rate}
  end

  defp extract_verification_metrics(_), do: {0, 1.0}

  defp analyze_gap(certainty, justification, weak_certainty, total_claims, verification_rate) do
    cond do
      # Case 1: Strong certainty + no claims = empty verification trap (HIGH risk)
      certainty and total_claims == 0 and not justification ->
        %{
          gap_detected: true,
          risk_level: :high,
          certainty_detected: true,
          has_justification: false,
          empty_trap: true,
          reason:
            "High confidence language with no verifiable claims - potential empty verification trap"
        }

      # Case 2: Strong certainty + low verification rate = potential hallucination (HIGH risk)
      certainty and total_claims > 0 and verification_rate < 0.5 and not justification ->
        %{
          gap_detected: true,
          risk_level: :high,
          certainty_detected: true,
          has_justification: false,
          empty_trap: false,
          reason:
            "High confidence with low verification rate (#{Float.round(verification_rate * 100, 1)}%) - claims may be ungrounded"
        }

      # Case 3: Certainty without justification but with some verification (MEDIUM risk)
      certainty and not justification and verification_rate >= 0.5 ->
        %{
          gap_detected: true,
          risk_level: :medium,
          certainty_detected: true,
          has_justification: false,
          empty_trap: false,
          reason: "Certainty language without explicit justification"
        }

      # Case 4: Weak certainty + no verification (LOW risk)
      weak_certainty and total_claims == 0 ->
        %{
          gap_detected: true,
          risk_level: :low,
          certainty_detected: false,
          has_justification: justification,
          empty_trap: true,
          reason: "No verifiable claims to check"
        }

      # Case 5: Certainty with justification - acceptable
      certainty and justification ->
        %{
          gap_detected: false,
          risk_level: :none,
          certainty_detected: true,
          has_justification: true,
          empty_trap: false,
          reason: nil
        }

      # Default: No issues detected
      true ->
        %{
          gap_detected: false,
          risk_level: :none,
          certainty_detected: certainty,
          has_justification: justification,
          empty_trap: false,
          reason: nil
        }
    end
  end
end
