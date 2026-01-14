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
    case classify_gap_case(
           certainty,
           justification,
           weak_certainty,
           total_claims,
           verification_rate
         ) do
      :empty_trap ->
        build_gap_result(
          :high,
          true,
          false,
          true,
          "High confidence language with no verifiable claims - potential empty verification trap"
        )

      :ungrounded ->
        build_gap_result(
          :high,
          true,
          false,
          false,
          "High confidence with low verification rate (#{Float.round(verification_rate * 100, 1)}%) - claims may be ungrounded"
        )

      :unjustified ->
        build_gap_result(
          :medium,
          true,
          false,
          false,
          "Certainty language without explicit justification"
        )

      :no_claims ->
        build_gap_result(:low, false, justification, true, "No verifiable claims to check")

      :acceptable ->
        build_gap_result(:none, true, true, false, nil)

      :no_issues ->
        build_gap_result(:none, certainty, justification, false, nil)
    end
  end

  # Classify the gap into a discrete case using pattern matching
  # Case 1: Strong certainty + no claims + no justification = empty trap
  defp classify_gap_case(true, false, _weak, 0, _rate), do: :empty_trap
  # Case 2: Strong certainty + claims + low verification + no justification = ungrounded
  defp classify_gap_case(true, false, _weak, claims, rate) when claims > 0 and rate < 0.5,
    do: :ungrounded

  # Case 3: Certainty without justification but with decent verification = unjustified
  defp classify_gap_case(true, false, _weak, _claims, rate) when rate >= 0.5, do: :unjustified
  # Case 4: Weak certainty + no claims = no claims to verify
  defp classify_gap_case(_cert, _just, true, 0, _rate), do: :no_claims
  # Case 5: Certainty with justification = acceptable
  defp classify_gap_case(true, true, _weak, _claims, _rate), do: :acceptable
  # Default: No issues
  defp classify_gap_case(_cert, _just, _weak, _claims, _rate), do: :no_issues

  # Build the gap result map
  defp build_gap_result(risk_level, certainty_detected, has_justification, empty_trap, reason) do
    %{
      gap_detected: risk_level != :none,
      risk_level: risk_level,
      certainty_detected: certainty_detected,
      has_justification: has_justification,
      empty_trap: empty_trap,
      reason: reason
    }
  end
end
