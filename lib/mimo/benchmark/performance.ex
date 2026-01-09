defmodule Mimo.Benchmark.Performance do
  @moduledoc """
  Production performance benchmarks for SPEC-061.

  Measures latency against competitor benchmarks:
  - Mem0: 1.44s p95 latency
  - Zep: 2.58s p95 latency
  - Mimo Target: <1.5s p95 latency

  ## Usage

      # Run all benchmarks
      Mimo.Benchmark.Performance.run_all()

      # Run specific benchmark
      Mimo.Benchmark.Performance.benchmark_memory_search()
      Mimo.Benchmark.Performance.benchmark_concurrent(concurrency: 50)

      # Run with options
      Mimo.Benchmark.Performance.run_all(iterations: 500, concurrency: 50)
  """

  require Logger
  alias Mimo.Brain.Memory

  # Target thresholds (from SPEC-061)
  @p95_target_ms 1500
  @p99_target_ms 3000
  @throughput_target_rps 100

  @doc """
  Run full performance benchmark suite.

  ## Options

    * `:iterations` - Number of iterations for latency tests (default: 500)
    * `:concurrency` - Number of concurrent workers (default: 50)
    * `:duration_ms` - Duration for concurrent load test (default: 10_000)
    * `:scales` - Memory counts to test at scale (default: [100, 1_000, 10_000])

  ## Returns

      %{
        memory_search: %{p50: ..., p95: ..., p99: ...},
        memory_store: %{p50: ..., p95: ..., p99: ...},
        tool_dispatch: %{p50: ..., p95: ..., p99: ...},
        concurrent_load: %{throughput_rps: ..., latencies: ...},
        memory_at_scale: %{100 => ..., 1000 => ..., ...},
        targets: %{p95_pass: true/false, ...}
      }
  """
  def run_all(opts \\ []) do
    Logger.info("[BENCHMARK] Starting performance benchmark suite")

    results = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      system: system_info(),
      memory_search: benchmark_memory_search(opts),
      memory_store: benchmark_memory_store(opts),
      tool_dispatch: benchmark_tool_dispatch(opts),
      concurrent_load: benchmark_concurrent(opts),
      memory_at_scale: benchmark_scale(opts)
    }

    # Calculate target comparison
    targets = calculate_targets(results)

    Map.put(results, :targets, targets)
  end

  @doc """
  Benchmark memory search latency.

  Performs semantic search queries and measures p50/p95/p99 latency.
  """
  def benchmark_memory_search(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 500)

    Logger.info("[BENCHMARK] Memory search: #{iterations} iterations")

    # Ensure we have test data
    ensure_test_memories(1000)

    # Generate varied queries for realistic testing
    queries = generate_test_queries(iterations)

    latencies =
      queries
      |> Enum.map(fn query ->
        {time, _result} =
          :timer.tc(fn ->
            Memory.search_memories(query, limit: 10)
          end)

        # Convert microseconds to ms
        time / 1000
      end)

    compute_percentiles(latencies)
  end

  @doc """
  Benchmark memory store latency.

  Stores new memories and measures write performance.
  """
  def benchmark_memory_store(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 200)

    Logger.info("[BENCHMARK] Memory store: #{iterations} iterations")

    latencies =
      1..iterations
      |> Enum.map(fn i ->
        content =
          "Benchmark memory #{i} - #{System.unique_integer([:positive])} with some content for embedding generation"

        {time, _result} =
          :timer.tc(fn ->
            Memory.persist_memory(content, :fact, 0.5, skip_novelty: true)
          end)

        time / 1000
      end)

    compute_percentiles(latencies)
  end

  @doc """
  Benchmark tool dispatch latency.

  Measures the overhead of routing through the tool dispatcher.
  """
  def benchmark_tool_dispatch(opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 500)

    Logger.info("[BENCHMARK] Tool dispatch: #{iterations} iterations")

    # Ensure test data exists
    ensure_test_memories(100)

    latencies =
      1..iterations
      |> Enum.map(fn _ ->
        {time, _result} =
          :timer.tc(fn ->
            Mimo.Tools.dispatch("memory", %{
              "operation" => "search",
              "query" => "test query #{:rand.uniform(100)}",
              "limit" => 5
            })
          end)

        time / 1000
      end)

    compute_percentiles(latencies)
  end

  @doc """
  Benchmark concurrent load.

  Spawns multiple workers performing mixed operations and measures
  throughput and latency under load.

  ## Options

    * `:concurrency` - Number of concurrent workers (default: 50)
    * `:duration_ms` - Test duration in milliseconds (default: 10_000)
  """
  def benchmark_concurrent(opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 50)
    duration_ms = Keyword.get(opts, :duration_ms, 10_000)

    Logger.info("[BENCHMARK] Concurrent load: #{concurrency} workers for #{duration_ms}ms")

    ensure_test_memories(1000)

    # Create ETS table for results
    results_table = Mimo.EtsSafe.ensure_table(:bench_results, [:public, :bag])

    start_time = System.monotonic_time(:millisecond)

    # Spawn concurrent workers
    tasks =
      1..concurrency
      |> Enum.map(fn worker_id ->
        Task.async(fn ->
          run_worker(worker_id, start_time, duration_ms, results_table)
        end)
      end)

    # Wait for all workers with timeout
    Enum.each(tasks, fn task ->
      Task.await(task, duration_ms + 30_000)
    end)

    # Collect results
    all_results = :ets.tab2list(results_table)
    :ets.delete(results_table)

    latencies = Enum.map(all_results, fn {_worker, latency, _op} -> latency end)
    operations = Enum.group_by(all_results, fn {_w, _l, op} -> op end)

    total_requests = length(latencies)
    actual_duration = max(duration_ms, 1)

    %{
      concurrency: concurrency,
      duration_ms: duration_ms,
      total_requests: total_requests,
      throughput_rps: Float.round(total_requests / (actual_duration / 1000), 2),
      operations: %{
        search: length(Map.get(operations, :search, [])),
        store: length(Map.get(operations, :store, []))
      },
      latencies: compute_percentiles(latencies)
    }
  end

  @doc """
  Benchmark performance at various memory scales.

  Tests search latency with different memory counts to verify
  O(log n) HNSW performance.
  """
  def benchmark_scale(opts \\ []) do
    scales = Keyword.get(opts, :scales, [100, 1_000, 10_000])

    Logger.info("[BENCHMARK] Scale test: #{inspect(scales)} memories")

    Enum.map(scales, fn target_count ->
      # Setup - ensure we have target_count memories
      current = Memory.count_memories()

      if current < target_count do
        ensure_test_memories(target_count)
      end

      # Measure search latency at this scale
      latencies =
        1..100
        |> Enum.map(fn _ ->
          {time, _} =
            :timer.tc(fn ->
              Memory.search_memories("benchmark query #{:rand.uniform(100)}", limit: 10)
            end)

          time / 1000
        end)

      {target_count, compute_percentiles(latencies)}
    end)
    |> Map.new()
  end

  defp run_worker(worker_id, start_time, duration_ms, results_table) do
    end_time = start_time + duration_ms
    run_worker_loop(worker_id, end_time, results_table, 0)
  end

  defp run_worker_loop(worker_id, end_time, results_table, count) do
    if System.monotonic_time(:millisecond) < end_time do
      # 70% reads, 30% writes (typical workload)
      {op, latency} =
        if :rand.uniform() < 0.7 do
          {time, _} =
            :timer.tc(fn ->
              Memory.search_memories("worker #{worker_id} query #{count}", limit: 5)
            end)

          {:search, time / 1000}
        else
          {time, _} =
            :timer.tc(fn ->
              Memory.persist_memory(
                "Worker #{worker_id} memory #{count}",
                :fact,
                0.5,
                skip_novelty: true
              )
            end)

          {:store, time / 1000}
        end

      :ets.insert(results_table, {worker_id, latency, op})
      run_worker_loop(worker_id, end_time, results_table, count + 1)
    else
      count
    end
  end

  defp ensure_test_memories(target_count) do
    current = Memory.count_memories()

    if current < target_count do
      to_create = target_count - current
      Logger.info("[BENCHMARK] Creating #{to_create} test memories...")

      # Batch insert for efficiency
      (current + 1)..target_count
      |> Enum.chunk_every(50)
      |> Enum.each(fn chunk ->
        Enum.each(chunk, fn i ->
          content = "Test memory #{i} for benchmarking with content about topic #{rem(i, 10)}"
          # Use direct insert for speed, bypassing embedding
          try do
            Memory.persist_memory(content, :fact, :rand.uniform(), skip_novelty: true)
          rescue
            _ -> :ok
          end
        end)
      end)

      Logger.info("[BENCHMARK] Created test memories, total: #{Memory.count_memories()}")
    end
  end

  defp generate_test_queries(count) do
    topics = [
      "project architecture patterns",
      "authentication flow",
      "database optimization",
      "error handling strategies",
      "API design principles",
      "memory management",
      "performance tuning",
      "security best practices",
      "testing strategies",
      "deployment configuration"
    ]

    1..count
    |> Enum.map(fn _ ->
      topic = Enum.random(topics)
      "#{topic} #{:rand.uniform(1000)}"
    end)
  end

  defp compute_percentiles([]), do: %{min: 0, max: 0, avg: 0, p50: 0, p90: 0, p95: 0, p99: 0}

  defp compute_percentiles(latencies) do
    sorted = Enum.sort(latencies)
    len = length(sorted)

    %{
      min: Float.round(Enum.min(sorted), 2),
      max: Float.round(Enum.max(sorted), 2),
      avg: Float.round(Enum.sum(sorted) / len, 2),
      p50: Float.round(percentile(sorted, 0.50), 2),
      p90: Float.round(percentile(sorted, 0.90), 2),
      p95: Float.round(percentile(sorted, 0.95), 2),
      p99: Float.round(percentile(sorted, 0.99), 2)
    }
  end

  defp percentile(sorted_list, p) when p >= 0 and p <= 1 do
    len = length(sorted_list)
    index = trunc(len * p)
    index = min(index, len - 1)
    Enum.at(sorted_list, index)
  end

  defp system_info do
    %{
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      elixir_version: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      memory_mb: Float.round(:erlang.memory(:total) / (1024 * 1024), 2),
      memory_count: Memory.count_memories()
    }
  end

  defp calculate_targets(results) do
    p95_search = get_in(results, [:memory_search, :p95]) || 0
    p99_search = get_in(results, [:memory_search, :p99]) || 0
    throughput = get_in(results, [:concurrent_load, :throughput_rps]) || 0

    %{
      p95_latency_ms: p95_search,
      p95_target_ms: @p95_target_ms,
      p95_pass: p95_search < @p95_target_ms,
      p99_latency_ms: p99_search,
      p99_target_ms: @p99_target_ms,
      p99_pass: p99_search < @p99_target_ms,
      throughput_rps: throughput,
      throughput_target_rps: @throughput_target_rps,
      throughput_pass: throughput >= @throughput_target_rps
    }
  end
end
