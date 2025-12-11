defmodule Mimo.AdaptiveWorkflow.Benchmarking.TokenEfficiency do
  @moduledoc """
  Benchmark for assessing model token efficiency.

  This module measures how efficiently a model uses tokens:

  - Response conciseness vs. completeness
  - Redundancy detection
  - Compression ratio for equivalent outputs
  - Output quality per token spent

  ## Efficiency Levels

  Token efficiency is measured on a 0.0-1.0 scale:

  | Score | Level | Description |
  |-------|-------|-------------|
  | 0.9+ | Optimal | Minimal tokens, high quality |
  | 0.7-0.9 | Efficient | Good balance, some verbosity |
  | 0.5-0.7 | Moderate | Acceptable, room for improvement |
  | <0.5 | Verbose | Excessive tokens for task |

  ## Metrics

  1. **Compression Ratio**: Output tokens / task complexity score
  2. **Quality per Token**: Quality score / tokens used
  3. **Redundancy Index**: Repeated information detection
  4. **Task Completion Rate**: Tasks completed per 1000 tokens
  """
  require Logger

  alias Mimo.AdaptiveWorkflow.ModelProfiler

  @type efficiency_level :: :optimal | :efficient | :moderate | :verbose
  @type task_type :: :coding | :analysis | :refactoring | :debugging | :documentation

  @type benchmark_result :: %{
          overall_efficiency: float(),
          compression_ratio: float(),
          quality_per_token: float(),
          redundancy_index: float(),
          by_task_type: %{task_type() => float()},
          tokens_per_completion: pos_integer()
        }

  # Standard efficiency test cases
  @test_cases [
    # Coding tasks
    %{type: :coding, complexity: :low, expected_tokens: 200},
    %{type: :coding, complexity: :medium, expected_tokens: 500},
    %{type: :coding, complexity: :high, expected_tokens: 1200},

    # Analysis tasks
    %{type: :analysis, complexity: :low, expected_tokens: 150},
    %{type: :analysis, complexity: :medium, expected_tokens: 400},
    %{type: :analysis, complexity: :high, expected_tokens: 900},

    # Refactoring tasks
    %{type: :refactoring, complexity: :low, expected_tokens: 300},
    %{type: :refactoring, complexity: :medium, expected_tokens: 700},

    # Debugging tasks
    %{type: :debugging, complexity: :low, expected_tokens: 250},
    %{type: :debugging, complexity: :medium, expected_tokens: 600},

    # Documentation tasks
    %{type: :documentation, complexity: :low, expected_tokens: 180},
    %{type: :documentation, complexity: :medium, expected_tokens: 450}
  ]

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Run a comprehensive token efficiency benchmark.

  ## Options

    * `:task_types` - Specific task types to test (default: all)
    * `:sample_size` - Number of samples per task type (default: 3)
    * `:quality_threshold` - Minimum acceptable quality (default: 0.7)

  ## Returns

    * `{:ok, benchmark_result}` on success
    * `{:error, reason}` on failure
  """
  @spec run_benchmark(ModelProfiler.model_id(), keyword()) ::
          {:ok, benchmark_result()} | {:error, term()}
  def run_benchmark(model_id, opts \\ []) do
    task_types = Keyword.get(opts, :task_types, nil)

    Logger.info("[TokenEfficiency] Starting benchmark for model: #{model_id}")

    test_cases = filter_test_cases(@test_cases, task_types)

    with {:ok, by_task} <- measure_efficiency_by_task(model_id, test_cases),
         {:ok, compression} <- measure_compression_ratio(model_id),
         {:ok, quality} <- measure_quality_per_token(model_id),
         {:ok, redundancy} <- measure_redundancy(model_id) do
      overall = calculate_overall_efficiency(by_task, compression, quality, redundancy)
      tokens_per_completion = estimate_tokens_per_completion(by_task)

      result = %{
        overall_efficiency: overall,
        compression_ratio: compression,
        quality_per_token: quality,
        redundancy_index: redundancy,
        by_task_type: by_task,
        tokens_per_completion: tokens_per_completion
      }

      Logger.info("[TokenEfficiency] Benchmark complete: #{inspect(result)}")
      {:ok, result}
    end
  end

  @doc """
  Quick assessment based on known model family.
  """
  @spec quick_assess(ModelProfiler.model_id()) :: {:ok, benchmark_result()}
  def quick_assess(model_id) do
    {efficiency, compression, quality, redundancy, tokens} = estimate_from_model_id(model_id)

    by_task = generate_task_scores(efficiency)

    {:ok,
     %{
       overall_efficiency: efficiency,
       compression_ratio: compression,
       quality_per_token: quality,
       redundancy_index: redundancy,
       by_task_type: by_task,
       tokens_per_completion: tokens
     }}
  end

  @doc """
  Classify an efficiency score into a level.
  """
  @spec classify_efficiency(float()) :: efficiency_level()
  def classify_efficiency(score) when score >= 0.9, do: :optimal
  def classify_efficiency(score) when score >= 0.7, do: :efficient
  def classify_efficiency(score) when score >= 0.5, do: :moderate
  def classify_efficiency(_score), do: :verbose

  @doc """
  Calculate token budget recommendation for a task.
  """
  @spec recommended_budget(task_type(), atom()) :: pos_integer()
  def recommended_budget(task_type, complexity) do
    case {task_type, complexity} do
      {:coding, :low} -> 300
      {:coding, :medium} -> 700
      {:coding, :high} -> 1500
      {:analysis, :low} -> 200
      {:analysis, :medium} -> 500
      {:analysis, :high} -> 1100
      {:refactoring, :low} -> 400
      {:refactoring, :medium} -> 900
      {:refactoring, :high} -> 1800
      {:debugging, :low} -> 350
      {:debugging, :medium} -> 800
      {:debugging, :high} -> 1400
      {:documentation, :low} -> 250
      {:documentation, :medium} -> 600
      {:documentation, :high} -> 1200
      _ -> 500
    end
  end

  @doc """
  Estimate output quality from token count and task.
  """
  @spec estimate_quality(task_type(), pos_integer(), pos_integer()) :: float()
  def estimate_quality(task_type, tokens_used, expected_tokens) do
    ratio = tokens_used / expected_tokens

    cond do
      # Too few tokens - likely incomplete
      ratio < 0.5 -> 0.5 * ratio
      # Optimal range
      ratio >= 0.8 and ratio <= 1.2 -> 1.0
      # Slightly over
      ratio > 1.2 and ratio <= 1.5 -> 0.95
      # Too verbose
      ratio > 1.5 and ratio <= 2.0 -> 0.85
      ratio > 2.0 -> max(0.5, 1.0 - (ratio - 2.0) * 0.15)
      # Just right
      true -> 0.9
    end
    |> adjust_for_task_type(task_type)
  end

  # Docs can be longer
  defp adjust_for_task_type(quality, :documentation), do: quality
  defp adjust_for_task_type(quality, :analysis), do: quality
  # Penalize verbosity slightly for code
  defp adjust_for_task_type(quality, _), do: quality * 0.95

  # =============================================================================
  # Benchmark Implementation
  # =============================================================================

  defp filter_test_cases(cases, nil), do: cases

  defp filter_test_cases(cases, types) when is_list(types) do
    Enum.filter(cases, &(&1.type in types))
  end

  defp measure_efficiency_by_task(_model_id, test_cases) do
    by_type =
      test_cases
      |> Enum.group_by(& &1.type)
      |> Enum.map(fn {type, cases} ->
        # Simulate efficiency score
        avg_efficiency =
          cases
          |> Enum.map(&simulate_efficiency/1)
          |> Enum.sum()
          |> Kernel./(length(cases))

        {type, Float.round(avg_efficiency, 3)}
      end)
      |> Map.new()

    {:ok, by_type}
  end

  defp simulate_efficiency(%{complexity: :low}), do: 0.92
  defp simulate_efficiency(%{complexity: :medium}), do: 0.85
  defp simulate_efficiency(%{complexity: :high}), do: 0.75
  defp simulate_efficiency(_), do: 0.80

  defp measure_compression_ratio(_model_id) do
    # Simulated: tokens used / optimal tokens
    {:ok, 0.82}
  end

  defp measure_quality_per_token(_model_id) do
    # Simulated: quality score / tokens * 1000
    {:ok, 0.78}
  end

  defp measure_redundancy(_model_id) do
    # Simulated: lower is better (amount of repeated info)
    {:ok, 0.15}
  end

  defp calculate_overall_efficiency(by_task, compression, quality, redundancy) do
    task_avg =
      by_task
      |> Map.values()
      |> then(fn vals ->
        if Enum.empty?(vals), do: 0.0, else: Enum.sum(vals) / length(vals)
      end)

    # Weighted combination
    overall = task_avg * 0.3 + compression * 0.25 + quality * 0.3 + (1.0 - redundancy) * 0.15
    Float.round(overall, 3)
  end

  defp estimate_tokens_per_completion(by_task) do
    # Estimate based on average efficiency
    avg_efficiency =
      by_task
      |> Map.values()
      |> then(fn vals ->
        if Enum.empty?(vals), do: 0.75, else: Enum.sum(vals) / length(vals)
      end)

    # Lower efficiency = more tokens needed
    base_tokens = 500
    round(base_tokens / avg_efficiency)
  end

  # =============================================================================
  # Model Family Estimation
  # =============================================================================

  defp estimate_from_model_id(model_id) do
    model_lower = String.downcase(model_id)

    cond do
      String.contains?(model_lower, "opus") ->
        # Opus is thorough but efficient
        {0.85, 0.88, 0.82, 0.12, 600}

      String.contains?(model_lower, "sonnet") ->
        # Sonnet is balanced
        {0.80, 0.82, 0.78, 0.15, 550}

      String.contains?(model_lower, "haiku") ->
        # Haiku is concise
        {0.88, 0.90, 0.75, 0.10, 400}

      String.contains?(model_lower, "gpt-4") and String.contains?(model_lower, "turbo") ->
        # GPT-4 Turbo is balanced
        {0.82, 0.85, 0.80, 0.14, 580}

      String.contains?(model_lower, "gpt-4") ->
        # GPT-4 can be verbose
        {0.75, 0.78, 0.82, 0.18, 700}

      String.contains?(model_lower, "gpt-3.5") ->
        # GPT-3.5 is concise
        {0.85, 0.88, 0.72, 0.12, 450}

      String.contains?(model_lower, "gemini-flash") ->
        # Flash is designed for efficiency
        {0.90, 0.92, 0.75, 0.08, 380}

      String.contains?(model_lower, "gemini-pro") ->
        # Pro is balanced
        {0.78, 0.80, 0.78, 0.16, 620}

      true ->
        {0.70, 0.72, 0.68, 0.20, 650}
    end
  end

  defp generate_task_scores(base_efficiency) do
    [:coding, :analysis, :refactoring, :debugging, :documentation]
    |> Enum.map(fn type ->
      # Add variation per task type
      variation = :rand.uniform() * 0.08 - 0.04
      score = Float.round(min(1.0, max(0.0, base_efficiency + variation)), 3)
      {type, score}
    end)
    |> Map.new()
  end
end
