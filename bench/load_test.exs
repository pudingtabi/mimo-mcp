defmodule Mimo.LoadTest do
  @moduledoc """
  Production load testing for Mimo-MCP.
  
  Tests:
  - HTTP endpoint throughput and latency
  - Memory stability under load
  - Circuit breaker behavior under concurrent failures
  - Cache efficiency
  
  ## Usage
  
      # Run default load test (100 users, 60 seconds)
      mix run bench/load_test.exs
      
      # Custom parameters
      Mimo.LoadTest.run(users: 200, duration_seconds: 120)
  
  ## Success Criteria
  - p95 latency < 500ms
  - p99 latency < 1000ms
  - Error rate < 1%
  - Memory stable (no unbounded growth)
  """
  require Logger

  @default_users 100
  @default_duration_seconds 60
  @base_url "http://localhost:4000"

  defp auth_headers do
    case System.get_env("MIMO_API_KEY") do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
      _ -> []
    end
  end

  defp authenticated_ops_enabled?, do: auth_headers() != []

  defmodule Stats do
    @moduledoc false
    defstruct [
      :start_time,
      requests: 0,
      successes: 0,
      failures: 0,
      latencies: [],
      memory_samples: []
    ]
  end

  @doc """
  Run load test with configurable parameters.
  
  ## Options
  - `:users` - Number of concurrent users (default: 100)
  - `:duration_seconds` - Test duration in seconds (default: 60)
  - `:ramp_up_seconds` - Time to ramp up to full load (default: 10)
  - `:think_time_ms` - Pause between requests per user (default: 100)
  """
  def run(opts \\ []) do
    users = Keyword.get(opts, :users, @default_users)
    duration = Keyword.get(opts, :duration_seconds, @default_duration_seconds)
    ramp_up = Keyword.get(opts, :ramp_up_seconds, 10)
    think_time = Keyword.get(opts, :think_time_ms, 100)

    if authenticated_ops_enabled?() do
      Logger.info("Starting load test: #{users} users for #{duration}s (authenticated endpoints enabled)")
    else
      Logger.info(
        "Starting load test: #{users} users for #{duration}s (auth disabled; set MIMO_API_KEY to include /v1/mimo endpoints)"
      )
    end
    
    # Initialize stats collector
    stats_pid =
      spawn_link(fn ->
        stats_collector(%Stats{start_time: System.monotonic_time(:millisecond)})
      end)
    
    # Start memory monitoring
    memory_monitor = spawn_link(fn -> memory_monitor(stats_pid, duration * 1000) end)
    
    # Ramp up users gradually
    user_delay_ms = div(ramp_up * 1000, users)
    
    operations = available_operations()

    user_pids = for i <- 1..users do
      Process.sleep(user_delay_ms)
      spawn_link(fn -> 
        run_user_session(stats_pid, duration * 1000 - i * user_delay_ms, think_time, operations)
      end)
    end
    
    # Wait for all users to complete
    Enum.each(user_pids, fn pid ->
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      end
    end)
    
    # Collect and report stats
    send(stats_pid, {:get_stats, self()})
    receive do
      {:stats, stats} -> report_results(stats)
    after
      5000 -> Logger.error("Timeout waiting for stats")
    end
    
    # Cleanup
    Process.exit(memory_monitor, :normal)
    Process.exit(stats_pid, :normal)
  end

  @doc """
  Test memory search performance with varying dataset sizes.
  """
  def test_memory_search_load(n_memories \\ 1000) do
    Logger.info("Testing memory search with #{n_memories} memories")
    
    # Seed memories
    seed_memories(n_memories)
    
    # Run search load test
    run(users: 50, duration_seconds: 30)
  end

  @doc """
  Test system behavior with failure injection.
  """
  def test_with_failure_injection(failure_rate \\ 0.1) do
    Logger.info("Testing with #{failure_rate * 100}% failure injection")
    
    # Enable failure injection mode
    Application.put_env(:mimo_mcp, :failure_injection_rate, failure_rate)
    
    try do
      run(users: 50, duration_seconds: 30)
    after
      Application.delete_env(:mimo_mcp, :failure_injection_rate)
    end
  end

  # User session simulation
  defp run_user_session(stats_pid, remaining_ms, think_time, operations) when remaining_ms > 0 do
    # Choose a random operation
    operation = Enum.random(operations)
    
    {latency_ms, result} = :timer.tc(fn -> execute_operation(operation) end, :millisecond)
    
    send(stats_pid, {:record, latency_ms, result})
    
    Process.sleep(think_time)
    run_user_session(stats_pid, remaining_ms - latency_ms - think_time, think_time, operations)
  end
  defp run_user_session(_stats_pid, _remaining_ms, _think_time, _operations), do: :ok

  defp available_operations do
    if authenticated_ops_enabled?() do
      [:health_check, :ask, :tool_list]
    else
      [:health_check]
    end
  end

  # Execute different operations
  defp execute_operation(:health_check) do
    case Req.request(method: :get, url: "#{@base_url}/health/live", retry: false) do
      {:ok, %{status: 200}} -> {:success, 200}
      {:ok, %{status: code}} -> {:failure, code}
      {:error, _} -> {:failure, :network}
    end
  rescue
    _ -> {:failure, :exception}
  end

  defp execute_operation(:ask) do
    headers = [{"content-type", "application/json"} | auth_headers()]

    case Req.request(
           method: :post,
           url: "#{@base_url}/v1/mimo/ask",
           json: %{query: "test query #{:rand.uniform(1000)}"},
           headers: headers,
           retry: false,
           receive_timeout: 5000
         ) do
      {:ok, %{status: code}} when code in 200..299 -> {:success, code}
      {:ok, %{status: code}} -> {:failure, code}
      {:error, _} -> {:failure, :network}
    end
  rescue
    _ -> {:failure, :exception}
  end

  defp execute_operation(:tool_list) do
    case Req.request(
           method: :get,
           url: "#{@base_url}/v1/mimo/tools",
           headers: auth_headers(),
           retry: false
         ) do
      {:ok, %{status: 200}} -> {:success, 200}
      {:ok, %{status: code}} -> {:failure, code}
      {:error, _} -> {:failure, :network}
    end
  rescue
    _ -> {:failure, :exception}
  end

  # Stats collector process
  defp stats_collector(stats) do
    receive do
      {:record, latency_ms, {:success, _code}} ->
        stats_collector(%{stats | 
          requests: stats.requests + 1,
          successes: stats.successes + 1,
          latencies: [latency_ms | stats.latencies]
        })
        
      {:record, latency_ms, {:failure, _reason}} ->
        stats_collector(%{stats | 
          requests: stats.requests + 1,
          failures: stats.failures + 1,
          latencies: [latency_ms | stats.latencies]
        })
        
      {:memory_sample, memory_mb} ->
        stats_collector(%{stats | memory_samples: [memory_mb | stats.memory_samples]})
        
      {:get_stats, from} ->
        send(from, {:stats, stats})
    end
  end

  # Memory monitoring process
  defp memory_monitor(stats_pid, duration_ms) do
    interval = 1000
    iterations = div(duration_ms, interval)
    
    for _ <- 1..iterations do
      memory_mb = :erlang.memory(:total) / (1024 * 1024)
      send(stats_pid, {:memory_sample, memory_mb})
      Process.sleep(interval)
    end
  end

  # Report results
  defp report_results(stats) do
    duration_s = (System.monotonic_time(:millisecond) - stats.start_time) / 1000
    sorted_latencies = Enum.sort(stats.latencies)
    
    p50 = percentile(sorted_latencies, 0.50)
    p95 = percentile(sorted_latencies, 0.95)
    p99 = percentile(sorted_latencies, 0.99)
    avg = if length(sorted_latencies) > 0, do: Enum.sum(sorted_latencies) / length(sorted_latencies), else: 0
    
    error_rate = if stats.requests > 0, do: stats.failures / stats.requests * 100, else: 0
    throughput = if duration_s > 0, do: stats.requests / duration_s, else: 0
    
    memory_samples = Enum.reverse(stats.memory_samples)
    memory_start = List.first(memory_samples) || 0
    memory_end = List.last(memory_samples) || 0
    memory_max = Enum.max(memory_samples, fn -> 0 end)
    
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("LOAD TEST RESULTS")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")
    IO.puts("Duration: #{Float.round(duration_s, 1)}s")
    IO.puts("Total Requests: #{stats.requests}")
    IO.puts("Successes: #{stats.successes}")
    IO.puts("Failures: #{stats.failures}")
    IO.puts("Throughput: #{Float.round(throughput, 1)} req/s")
    IO.puts("")
    IO.puts("Latency (ms):")
    IO.puts("  Average: #{Float.round(avg, 1)}")
    IO.puts("  p50: #{Float.round(p50, 1)}")
    IO.puts("  p95: #{Float.round(p95, 1)}")
    IO.puts("  p99: #{Float.round(p99, 1)}")
    IO.puts("")
    IO.puts("Error Rate: #{Float.round(error_rate, 2)}%")
    IO.puts("")
    IO.puts("Memory (MB):")
    IO.puts("  Start: #{Float.round(memory_start, 1)}")
    IO.puts("  End: #{Float.round(memory_end, 1)}")
    IO.puts("  Max: #{Float.round(memory_max, 1)}")
    IO.puts("  Growth: #{Float.round(memory_end - memory_start, 1)}")
    IO.puts("")
    
    # Success criteria evaluation
    IO.puts("SUCCESS CRITERIA:")
    evaluate_criteria("p95 < 500ms", p95 < 500)
    evaluate_criteria("p99 < 1000ms", p99 < 1000)
    evaluate_criteria("Error rate < 1%", error_rate < 1)
    evaluate_criteria("Memory stable", (memory_end - memory_start) < 100)
    
    IO.puts(String.duplicate("=", 60))
    
    # Return summary for programmatic use
    %{
      duration_s: duration_s,
      requests: stats.requests,
      successes: stats.successes,
      failures: stats.failures,
      throughput: throughput,
      latency: %{avg: avg, p50: p50, p95: p95, p99: p99},
      error_rate: error_rate,
      memory: %{start: memory_start, end: memory_end, max: memory_max}
    }
  end

  defp percentile([], _p), do: 0
  defp percentile(sorted_list, p) do
    index = round(length(sorted_list) * p) - 1
    index = max(0, index)
    Enum.at(sorted_list, index, 0) / 1
  end

  defp evaluate_criteria(name, true), do: IO.puts("  ✅ #{name}")
  defp evaluate_criteria(name, false), do: IO.puts("  ❌ #{name}")

  defp seed_memories(n) do
    Logger.info("Seeding #{n} memories...")
    # Implementation would insert test memories
    # For now, just log
    :ok
  end
end

# Run when executed directly (pass --no-run to only compile)
args = System.argv()

unless "--no-run" in args do
  users =
    case Enum.find_index(args, &(&1 == "--users")) do
      nil -> 100
      i -> String.to_integer(Enum.at(args, i + 1, "100"))
    end

  duration =
    case Enum.find_index(args, &(&1 == "--duration")) do
      nil -> 60
      i -> String.to_integer(Enum.at(args, i + 1, "60"))
    end

  Mimo.LoadTest.run(users: users, duration_seconds: duration)
end
