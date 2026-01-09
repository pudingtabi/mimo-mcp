defmodule Mimo.Brain.Reflector.ConfidenceOutput do
  @moduledoc """
  Formats outputs with confidence indicators.

  Part of SPEC-043: Reflective Intelligence System.

  Provides multiple output formats for communicating confidence:
  - **Structured**: Machine-readable format with metadata
  - **Natural**: Human-readable with natural language qualifiers
  - **Hidden**: No visible confidence (but metadata available)

  ## Example

      confidence = ConfidenceEstimator.estimate(output, context)
      formatted = ConfidenceOutput.format(output, confidence)

      # Structured format:
      %{
        content: "The answer is...",
        confidence: %{
          level: :high,
          score: 0.82,
          indicator: "●●●●○"
        }
      }

      # Natural format:
      "From what I understand, the answer is..."
  """

  @type format_type :: :structured | :natural | :hidden

  @type formatted_output :: %{
          content: String.t(),
          confidence: map(),
          metadata: map()
        }

  @doc """
  Format output with confidence information.

  ## Options

  - `:format` - Output format (:structured | :natural | :hidden), default: :structured
  - `:include_explanation` - Include confidence explanation (default: true)
  """
  @spec format(String.t(), map(), keyword()) :: formatted_output()
  def format(output, confidence, opts \\ []) do
    format_type = Keyword.get(opts, :format, :structured)
    include_explanation = Keyword.get(opts, :include_explanation, true)

    case format_type do
      :structured -> format_structured(output, confidence, include_explanation)
      :natural -> format_natural(output, confidence)
      :hidden -> format_hidden(output, confidence)
    end
  end

  @doc """
  Get a visual confidence indicator.

  Returns a string like "●●●●○" representing confidence level.
  """
  @spec confidence_indicator(float() | atom()) :: String.t()
  def confidence_indicator(score) when is_float(score) do
    filled = round(score * 5)
    empty = 5 - filled

    String.duplicate("●", filled) <> String.duplicate("○", empty)
  end

  def confidence_indicator(level) when is_atom(level) do
    case level do
      :very_high -> "●●●●●"
      :high -> "●●●●○"
      :medium -> "●●●○○"
      :low -> "●●○○○"
      :very_low -> "●○○○○"
      _ -> "○○○○○"
    end
  end

  @doc """
  Get confidence badge text.
  """
  @spec confidence_badge(atom()) :: String.t()
  def confidence_badge(level) do
    case level do
      :very_high -> "✓ Verified"
      :high -> "✓ Confident"
      :medium -> "~ Likely"
      :low -> "? Uncertain"
      :very_low -> "⚠ Speculative"
      _ -> "? Unknown"
    end
  end

  @doc """
  Get appropriate prefix for response based on confidence.
  """
  @spec response_prefix(atom()) :: String.t() | nil
  def response_prefix(level) do
    case level do
      # No prefix needed - direct assertion
      :very_high -> nil
      :high -> "Based on my understanding, "
      :medium -> "I believe "
      :low -> "I'm not entirely certain, but "
      :very_low -> "I don't have strong information on this, but "
      _ -> "From what I can tell, "
    end
  end

  defp format_structured(output, confidence, include_explanation) do
    %{
      content: output,
      confidence: %{
        level: confidence.level,
        score: confidence.score,
        indicator: confidence_indicator(confidence.score),
        badge: confidence_badge(confidence.level),
        explanation: if(include_explanation, do: confidence.explanation, else: nil),
        signals: confidence.signals
      },
      metadata: %{
        calibrated: confidence.calibrated,
        formatted_at: DateTime.utc_now(),
        format: :structured
      }
    }
  end

  defp format_natural(output, confidence) do
    prefix = response_prefix(confidence.level)

    content =
      if prefix do
        prefix <> lowercase_first(output)
      else
        output
      end

    # Add uncertainty suffix for low confidence
    content =
      if confidence.level in [:low, :very_low] do
        content <> " Please verify this information independently."
      else
        content
      end

    %{
      content: content,
      confidence: %{
        level: confidence.level,
        score: confidence.score,
        indicator: confidence_indicator(confidence.score)
      },
      metadata: %{
        original_content: output,
        modified: prefix != nil,
        format: :natural
      }
    }
  end

  defp format_hidden(output, confidence) do
    %{
      content: output,
      confidence: %{
        level: confidence.level,
        score: confidence.score
        # No visible indicators
      },
      metadata: %{
        full_confidence: confidence,
        format: :hidden
      }
    }
  end

  defp lowercase_first(<<first::utf8, rest::binary>>) do
    String.downcase(<<first::utf8>>) <> rest
  end

  defp lowercase_first(other), do: other
end
