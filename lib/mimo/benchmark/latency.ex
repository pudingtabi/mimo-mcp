defmodule Mimo.Benchmark.Latency do
  @moduledoc """
  SPEC-074: Latency Benchmarks

  Measures actual latency of core Mimo operations to validate
  performance claims. Run periodically to ensure <50ms target.

  ## Usage

      Mimo.Benchmark.Latency.run_all()
      Mimo.Benchmark.Latency.run(:memory_search)
      Mimo.Benchmark.Latency.report()
  """

  require Logger

  alias Mimo.Brain.MemoryRouter
  alias Mimo.MetaCognitiveRouter
  alias Mimo.Cognitive.FeedbackLoop

  @target_latency_ms 50
  @warmup_runs 3
  @benchmark_runs 10

  @doc """
  Run all benchmarks and return a comprehensive report.
  """
  @spec run_all() :: map()
  def run_all do
    benchmarks = [
      :router_classify,
      :memory_search,
      :memory_search_cached,
      :feedback_record,
      :feedback_query
    ]

    results =
      benchmarks
      |> Enum.map(fn bench ->
        result = run(bench)
        {bench, result}
      end)
      |> Map.new()

    %{
      results: results,
      summary: summarize(results),
      target_met: all_under_target?(results),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Run a specific benchmark.
  """
  @spec run(atom()) :: map()
  def run(benchmark) do
    # Warmup
    for _ <- 1..@warmup_runs do
      run_single(benchmark)
    end

    # Actual measurements
    measurements =
      for _ <- 1..@benchmark_runs do
        {time_us, _result} = :timer.tc(fn -> run_single(benchmark) end)
        # Convert to ms
        time_us / 1000
      end

    analyze_measurements(benchmark, measurements)
  end

  @doc """
  Generate a human-readable report.
  """
  @spec report() :: String.t()
  def report do
    results = run_all()

    lines = [
      "=" |> String.duplicate(60),
      "MIMO LATENCY BENCHMARK REPORT",
      "Target: <#{@target_latency_ms}ms",
      "=" |> String.duplicate(60),
      ""
    ]

    result_lines =
      results.results
      |> Enum.map(fn {bench, data} ->
        status = if data.p95 < @target_latency_ms, do: "✓ PASS", else: "✗ FAIL"

        """
        #{bench}:
          Min:    #{Float.round(data.min, 2)}ms
          Avg:    #{Float.round(data.avg, 2)}ms
          P95:    #{Float.round(data.p95, 2)}ms
          Max:    #{Float.round(data.max, 2)}ms
          Status: #{status}
        """
      end)

    summary_lines = [
      "",
      "-" |> String.duplicate(60),
      "SUMMARY",
      "-" |> String.duplicate(60),
      "Total benchmarks: #{map_size(results.results)}",
      "Passing: #{results.summary.passing}/#{results.summary.total}",
      "Overall: #{if results.target_met, do: "✓ ALL TARGETS MET", else: "✗ SOME TARGETS MISSED"}",
      "=" |> String.duplicate(60)
    ]

    (lines ++ result_lines ++ summary_lines)
    |> Enum.join("\n")
  end

  # ==========================================================================
  # Individual Benchmarks
  # ==========================================================================

  defp run_single(:router_classify) do
    queries = [
      "Fix the authentication bug",
      "What modules depend on User?",
      "Remember our discussion yesterday"
    ]

    query = Enum.random(queries)
    MetaCognitiveRouter.classify(query)
  end

  defp run_single(:memory_search) do
    queries = ["authentication", "error handling", "database"]
    query = Enum.random(queries)
    MemoryRouter.route(query, limit: 10, skip_cache: true)
  end

  defp run_single(:memory_search_cached) do
    # Use consistent query to hit cache
    MemoryRouter.route("benchmark test query", limit: 10)
  end

  defp run_single(:feedback_record) do
    FeedbackLoop.record_outcome(
      :prediction,
      %{query: "benchmark", predicted_needs: [:test]},
      %{success: true, latency_ms: 10}
    )
  end

  defp run_single(:feedback_query) do
    FeedbackLoop.query_patterns(:prediction)
  end

  # ==========================================================================
  # Analysis
  # ==========================================================================

  defp analyze_measurements(benchmark, measurements) do
    sorted = Enum.sort(measurements)
    count = length(sorted)

    %{
      benchmark: benchmark,
      runs: count,
      min: Enum.min(sorted),
      max: Enum.max(sorted),
      avg: Enum.sum(sorted) / count,
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      under_target: Enum.count(sorted, &(&1 < @target_latency_ms)),
      measurements: sorted
    }
  end

  defp percentile(sorted_list, p) do
    index = round(length(sorted_list) * p / 100) - 1
    index = max(0, min(index, length(sorted_list) - 1))
    Enum.at(sorted_list, index)
  end

  defp summarize(results) do
    total = map_size(results)
    passing = Enum.count(results, fn {_, data} -> data.p95 < @target_latency_ms end)

    %{
      total: total,
      passing: passing,
      failing: total - passing,
      pass_rate: if(total > 0, do: passing / total, else: 0)
    }
  end

  defp all_under_target?(results) do
    Enum.all?(results, fn {_, data} -> data.p95 < @target_latency_ms end)
  end
end
