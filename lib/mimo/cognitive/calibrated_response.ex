defmodule Mimo.Cognitive.CalibratedResponse do
  @moduledoc """
  Generates responses with appropriate confidence indicators.

  Formats responses based on the assessed uncertainty level,
  adding appropriate prefixes, caveats, and confidence indicators.

  ## Example

      uncertainty = ConfidenceAssessor.assess("How does Phoenix work?")
      response = CalibratedResponse.format_response("Phoenix uses...", uncertainty)

      # For high confidence:
      "Based on my knowledge, Phoenix uses..."

      # For low confidence:
      "I'm not entirely certain, but Phoenix uses...
       _Confidence: Low | 2 sources_"
  """

  alias Mimo.Cognitive.Uncertainty

  @type response_style :: :formal | :conversational | :minimal

  @confidence_prefixes %{
    high: [
      "Based on my knowledge,",
      "I'm confident that",
      "According to the information I have,",
      "From what I know,"
    ],
    medium: [
      "From what I understand,",
      "I believe",
      "It seems that",
      "Based on available information,",
      "As far as I can tell,"
    ],
    low: [
      "I'm not entirely certain, but",
      "Based on limited information,",
      "I think, though I'm not sure,",
      "From what little I know,",
      "With some uncertainty,"
    ],
    unknown: [
      "I don't have reliable information about this.",
      "This is outside my current knowledge.",
      "I'd need to research this further.",
      "I don't have specific information on this topic.",
      "I'm not familiar with this area."
    ]
  }

  @confidence_colors %{
    high: "🟢",
    medium: "🟡",
    low: "🟠",
    unknown: "🔴"
  }

  @doc """
  Format a response with appropriate confidence indicators.

  ## Options

  - `:style` - Response style (:formal, :conversational, :minimal)
  - `:include_sources` - Include source information (default: true for low confidence)
  - `:include_emoji` - Include confidence emoji (default: false)
  - `:include_score` - Include numeric score (default: false)
  """
  @spec format_response(String.t(), Uncertainty.t(), keyword()) :: String.t()
  def format_response(content, %Uncertainty{} = uncertainty, opts \\ []) do
    style = Keyword.get(opts, :style, :conversational)

    include_sources =
      Keyword.get(opts, :include_sources, uncertainty.confidence in [:low, :unknown])

    include_emoji = Keyword.get(opts, :include_emoji, false)
    include_score = Keyword.get(opts, :include_score, false)

    prefix = get_confidence_prefix(uncertainty.confidence, style)
    suffix = build_suffix(uncertainty, include_sources, include_emoji, include_score)

    formatted_content =
      cond do
        uncertainty.confidence == :unknown ->
          # For unknown, the prefix IS the response
          prefix

        String.starts_with?(content, prefix) ->
          content

        true ->
          "#{prefix} #{content}"
      end

    if suffix && suffix != "" do
      "#{formatted_content}\n\n#{suffix}"
    else
      formatted_content
    end
  end

  @doc """
  Generate a confidence indicator string.
  """
  @spec confidence_indicator(Uncertainty.t(), keyword()) :: String.t()
  def confidence_indicator(%Uncertainty{} = uncertainty, opts \\ []) do
    include_emoji = Keyword.get(opts, :include_emoji, true)
    include_score = Keyword.get(opts, :include_score, true)
    include_sources = Keyword.get(opts, :include_sources, false)

    parts = []

    parts =
      if include_emoji do
        emoji = Map.get(@confidence_colors, uncertainty.confidence, "⚪")
        ["#{emoji} #{confidence_label(uncertainty.confidence)}" | parts]
      else
        [confidence_label(uncertainty.confidence) | parts]
      end

    parts =
      if include_score do
        ["#{Float.round(uncertainty.score * 100, 0)}%" | parts]
      else
        parts
      end

    parts =
      if include_sources and uncertainty.evidence_count > 0 do
        ["#{uncertainty.evidence_count} sources" | parts]
      else
        parts
      end

    Enum.reverse(parts) |> Enum.join(" | ")
  end

  @doc """
  Generate a caveat message for uncertain responses.
  """
  @spec caveat_message(Uncertainty.t()) :: String.t() | nil
  def caveat_message(%Uncertainty{confidence: :high}), do: nil
  def caveat_message(%Uncertainty{confidence: :medium, staleness: s}) when s < 0.3, do: nil

  def caveat_message(%Uncertainty{} = uncertainty) do
    messages = []

    messages =
      if uncertainty.confidence in [:low, :unknown] do
        ["This information may not be complete or accurate." | messages]
      else
        messages
      end

    messages =
      if uncertainty.staleness >= 0.5 do
        ["This information may be outdated." | messages]
      else
        messages
      end

    messages =
      if length(uncertainty.gap_indicators) > 0 do
        gaps = Enum.take(uncertainty.gap_indicators, 2) |> Enum.join("; ")
        ["Note: #{gaps}" | messages]
      else
        messages
      end

    case messages do
      [] -> nil
      msgs -> "_#{Enum.join(Enum.reverse(msgs), " ")} _"
    end
  end

  @doc """
  Generate an "I don't know" response with suggestions.
  """
  @spec unknown_response(String.t(), Uncertainty.t(), keyword()) :: String.t()
  def unknown_response(query, %Uncertainty{} = uncertainty, opts \\ []) do
    include_suggestions = Keyword.get(opts, :include_suggestions, true)

    base = Enum.random(@confidence_prefixes.unknown)

    suggestions =
      if include_suggestions do
        build_suggestions(query, uncertainty)
      else
        nil
      end

    if suggestions do
      "#{base}\n\n#{suggestions}"
    else
      base
    end
  end

  @doc """
  Format multiple response options with different confidence levels.
  Useful when presenting alternatives.
  """
  @spec format_alternatives([{String.t(), Uncertainty.t()}]) :: String.t()
  def format_alternatives(alternatives) do
    alternatives
    |> Enum.sort_by(fn {_, u} -> -u.score end)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n---\n\n", fn {{content, uncertainty}, index} ->
      indicator = confidence_indicator(uncertainty, include_emoji: true)
      "**Option #{index}** (#{indicator})\n#{content}"
    end)
  end

  # Private functions

  defp get_confidence_prefix(confidence, _style) do
    prefixes = Map.get(@confidence_prefixes, confidence, @confidence_prefixes.unknown)
    Enum.random(prefixes)
  end

  defp build_suffix(uncertainty, include_sources, include_emoji, include_score) do
    parts = []

    # Add caveat if needed
    caveat = caveat_message(uncertainty)
    parts = if caveat, do: [caveat | parts], else: parts

    # Add confidence indicator for low confidence
    parts =
      if uncertainty.confidence in [:low, :unknown] or include_score do
        indicator =
          confidence_indicator(uncertainty,
            include_emoji: include_emoji,
            include_score: include_score,
            include_sources: include_sources
          )

        ["_Confidence: #{indicator}_" | parts]
      else
        parts
      end

    parts
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp build_suggestions(query, uncertainty) do
    suggestions = []

    # Suggest based on gaps
    suggestions =
      uncertainty.gap_indicators
      |> Enum.take(2)
      |> Enum.reduce(suggestions, fn gap, acc ->
        cond do
          String.contains?(gap, "documentation") ->
            ["- I could fetch the relevant documentation for you" | acc]

          String.contains?(gap, "code") ->
            ["- Would you like me to search the codebase?" | acc]

          true ->
            acc
        end
      end)

    # General suggestions
    suggestions =
      if uncertainty.evidence_count == 0 do
        [
          "- Could you provide more context about #{query}?",
          "- Would you like me to search the web for this?"
          | suggestions
        ]
      else
        suggestions
      end

    case suggestions do
      [] ->
        nil

      sugs ->
        """
        However, I can help by:
        #{Enum.reverse(sugs) |> Enum.join("\n")}
        """
    end
  end

  defp confidence_label(:high), do: "High confidence"
  defp confidence_label(:medium), do: "Moderate confidence"
  defp confidence_label(:low), do: "Low confidence"
  defp confidence_label(:unknown), do: "Unknown"
end
