defmodule Mimo.Gateway.OutputValidator do
  @moduledoc """
  Output Validator - Post-tool enforcement layer.

  Validates tool outputs:
  - Detects verification claims without proof
  - Triggers auto-learning
  - Quality checks
  """

  require Logger

  alias Mimo.Gateway.Session

  # Patterns that indicate verification claims
  @verification_patterns [
    ~r/I (?:have )?verified/i,
    ~r/I (?:have )?confirmed/i,
    ~r/I (?:have )?tested/i,
    ~r/verification (?:is )?complete/i,
    ~r/successfully tested/i
  ]

  @doc """
  Validate tool output before returning to user.
  """
  def validate(%Session{} = session, tool_name, result) do
    result =
      result
      |> check_verification_claims(tool_name)
      |> add_gateway_metadata(session)

    {:ok, session, result}
  end

  # Check for verification claims without proof
  defp check_verification_claims(result, _tool_name) when is_map(result) do
    text = extract_text_content(result)

    if contains_verification_claim?(text) and not has_proof?(result) do
      add_warning(
        result,
        "⚠️ Verification claimed but no proof found. Consider running actual tests."
      )
    else
      result
    end
  end

  defp check_verification_claims(result, _), do: result

  # Check if text contains verification claims
  defp contains_verification_claim?(nil), do: false

  defp contains_verification_claim?(text) when is_binary(text) do
    Enum.any?(@verification_patterns, fn pattern ->
      Regex.match?(pattern, text)
    end)
  end

  defp contains_verification_claim?(_), do: false

  # Check if result contains actual proof (test output, etc.)
  defp has_proof?(result) when is_map(result) do
    # Look for indicators of actual execution
    has_test_output?(result) or
      has_command_output?(result) or
      has_error_trace?(result)
  end

  defp has_proof?(_), do: false

  defp has_test_output?(result) do
    text = extract_text_content(result)

    text &&
      (String.contains?(text, "test") or
         String.contains?(text, "PASS") or
         String.contains?(text, "FAIL") or
         String.contains?(text, "✓") or
         String.contains?(text, "✗"))
  end

  defp has_command_output?(result) do
    Map.has_key?(result, :output) or
      Map.has_key?(result, "output") or
      Map.has_key?(result, :stdout)
  end

  defp has_error_trace?(result) do
    text = extract_text_content(result)
    text && String.contains?(text, "Error:")
  end

  # Extract text content from result
  defp extract_text_content(%{data: data}) when is_map(data) do
    Map.get(data, :content) || Map.get(data, :message) || inspect(data)
  end

  defp extract_text_content(%{"data" => data}) when is_map(data) do
    Map.get(data, "content") || Map.get(data, "message") || inspect(data)
  end

  defp extract_text_content(result) when is_map(result) do
    Map.get(result, :content) || Map.get(result, "content") || inspect(result)
  end

  defp extract_text_content(_), do: nil

  # Add warning to result
  defp add_warning(result, warning) when is_map(result) do
    warnings = Map.get(result, :gateway_warnings, [])
    Map.put(result, :gateway_warnings, [warning | warnings])
  end

  # Add gateway metadata
  defp add_gateway_metadata(result, %Session{id: id, phase: phase}) when is_map(result) do
    Map.put(result, :_gateway, %{
      session_id: id,
      phase: phase,
      timestamp: DateTime.utc_now()
    })
  end

  defp add_gateway_metadata(result, _), do: result
end
