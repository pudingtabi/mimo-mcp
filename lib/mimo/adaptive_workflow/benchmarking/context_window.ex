defmodule Mimo.AdaptiveWorkflow.Benchmarking.ContextWindow do
  @moduledoc """
  Benchmark for assessing model context window capabilities.

  This module provides standardized micro-tasks to measure how effectively
  a model can handle different context sizes, including:

  - Maximum usable tokens before degradation
  - Information retention across long contexts
  - Needle-in-haystack retrieval accuracy
  - Context coherence maintenance

  ## Assessment Levels

  Based on estimated context window capabilities:

  | Level | Token Range | Description |
  |-------|-------------|-------------|
  | :minimal | 0-8K | Very limited context |
  | :small | 8K-32K | Standard small model |
  | :medium | 32K-128K | Extended context |
  | :large | 128K-200K | Large context window |
  | :extended | 200K+ | Very large context |

  ## Benchmarking Strategy

  1. **Progressive Load Test**: Increase context size until degradation
  2. **Needle-in-Haystack**: Measure retrieval accuracy at various depths
  3. **Coherence Test**: Check for context loss in long interactions
  """
  require Logger

  alias Mimo.AdaptiveWorkflow.ModelProfiler

  @type context_level :: :minimal | :small | :medium | :large | :extended
  @type benchmark_result :: %{
          level: context_level(),
          estimated_tokens: pos_integer(),
          retrieval_accuracy: float(),
          coherence_score: float(),
          degradation_point: pos_integer() | nil
        }

  # Token ranges for each level
  @context_levels %{
    minimal: {0, 8_000},
    small: {8_000, 32_000},
    medium: {32_000, 128_000},
    large: {128_000, 200_000},
    extended: {200_000, 1_000_000}
  }

  # Standard test payloads of increasing size (approximate token counts)
  @test_sizes [1_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 200_000]

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Run a comprehensive context window benchmark for a model.

  ## Options

    * `:max_test_size` - Maximum token size to test (default: 200_000)
    * `:min_accuracy` - Minimum acceptable retrieval accuracy (default: 0.8)
    * `:test_depth` - Number of needle-in-haystack tests per size (default: 3)

  ## Returns

    * `{:ok, benchmark_result}` on success
    * `{:error, reason}` on failure
  """
  @spec run_benchmark(ModelProfiler.model_id(), keyword()) :: {:ok, benchmark_result()} | {:error, term()}
  def run_benchmark(model_id, opts \\ []) do
    max_size = Keyword.get(opts, :max_test_size, 200_000)
    min_accuracy = Keyword.get(opts, :min_accuracy, 0.8)
    test_depth = Keyword.get(opts, :test_depth, 3)

    Logger.info("[ContextWindow] Starting benchmark for model: #{model_id}")

    with {:ok, degradation_point} <- find_degradation_point(model_id, max_size, min_accuracy),
         {:ok, retrieval_accuracy} <- measure_retrieval_accuracy(model_id, degradation_point, test_depth),
         {:ok, coherence_score} <- measure_coherence(model_id, degradation_point) do
      level = classify_context_level(degradation_point)

      result = %{
        level: level,
        estimated_tokens: degradation_point,
        retrieval_accuracy: retrieval_accuracy,
        coherence_score: coherence_score,
        degradation_point: degradation_point
      }

      Logger.info("[ContextWindow] Benchmark complete: #{inspect(result)}")
      {:ok, result}
    end
  end

  @doc """
  Quick assessment based on known model family.

  Uses documented context limits rather than active benchmarking.
  """
  @spec quick_assess(ModelProfiler.model_id()) :: {:ok, benchmark_result()}
  def quick_assess(model_id) do
    # Get estimated context from model family
    estimated = estimate_from_model_id(model_id)
    level = classify_context_level(estimated)

    {:ok,
     %{
       level: level,
       estimated_tokens: estimated,
       retrieval_accuracy: default_accuracy_for_level(level),
       coherence_score: default_coherence_for_level(level),
       degradation_point: nil
     }}
  end

  @doc """
  Classify a token count into a context level.
  """
  @spec classify_context_level(pos_integer()) :: context_level()
  def classify_context_level(tokens) do
    cond do
      tokens < 8_000 -> :minimal
      tokens < 32_000 -> :small
      tokens < 128_000 -> :medium
      tokens < 200_000 -> :large
      true -> :extended
    end
  end

  @doc """
  Get the token range for a context level.
  """
  @spec level_range(context_level()) :: {pos_integer(), pos_integer()}
  def level_range(level), do: Map.get(@context_levels, level, {0, 8_000})

  # =============================================================================
  # Benchmark Implementation
  # =============================================================================

  defp find_degradation_point(model_id, max_size, min_accuracy) do
    # Filter test sizes up to max_size
    sizes_to_test = Enum.filter(@test_sizes, &(&1 <= max_size))

    # Binary search for degradation point
    result =
      Enum.reduce_while(sizes_to_test, nil, fn size, _last_good ->
        case test_at_size(model_id, size) do
          {:ok, accuracy} when accuracy >= min_accuracy ->
            {:cont, size}

          {:ok, _accuracy} ->
            # Found degradation point (accuracy below threshold)
            {:halt, {:found, size}}
        end
      end)

    case result do
      {:found, size} -> {:ok, size}
      nil -> {:ok, max_size}
      size when is_integer(size) -> {:ok, size}
    end
  end

  defp test_at_size(_model_id, _size) do
    # Simulated test - in production this would make actual API calls
    # For now, return success based on typical model behavior
    {:ok, 0.95}
  end

  defp measure_retrieval_accuracy(_model_id, _context_size, _depth) do
    # Simulated needle-in-haystack test
    # In production: insert unique markers at various depths and test retrieval
    {:ok, 0.92}
  end

  defp measure_coherence(_model_id, _context_size) do
    # Simulated coherence test
    # In production: test multi-turn conversations for context loss
    {:ok, 0.88}
  end

  # =============================================================================
  # Model Family Estimation
  # =============================================================================

  defp estimate_from_model_id(model_id) do
    model_lower = String.downcase(model_id)

    cond do
      String.contains?(model_lower, "opus") -> 200_000
      String.contains?(model_lower, "sonnet") -> 200_000
      String.contains?(model_lower, "haiku") -> 200_000
      String.contains?(model_lower, "gpt-4") and String.contains?(model_lower, "turbo") -> 128_000
      String.contains?(model_lower, "gpt-4") -> 32_000
      String.contains?(model_lower, "gpt-3.5") -> 16_000
      String.contains?(model_lower, "gemini-pro") -> 32_000
      String.contains?(model_lower, "gemini-flash") -> 1_000_000
      true -> 8_000
    end
  end

  defp default_accuracy_for_level(:extended), do: 0.90
  defp default_accuracy_for_level(:large), do: 0.92
  defp default_accuracy_for_level(:medium), do: 0.90
  defp default_accuracy_for_level(:small), do: 0.85
  defp default_accuracy_for_level(:minimal), do: 0.75

  defp default_coherence_for_level(:extended), do: 0.85
  defp default_coherence_for_level(:large), do: 0.88
  defp default_coherence_for_level(:medium), do: 0.85
  defp default_coherence_for_level(:small), do: 0.80
  defp default_coherence_for_level(:minimal), do: 0.70
end
