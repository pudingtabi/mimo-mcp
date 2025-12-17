defmodule Mimo.Bench do
  @moduledoc """
  Benchmark suite for Mimo MCP performance testing.
  
  ## Usage
  
      # Run all benchmarks
      mix run bench/runner.exs
      
      # Run specific benchmark
      Mimo.Bench.run(:memory_search)
      Mimo.Bench.run(:vector_math)
      Mimo.Bench.run(:semantic_query)
  
  ## Results
  
  Results are saved to `bench/results/` with timestamps.
  """

  require Logger

  @results_dir "bench/results"

  def run(benchmark \\ :all) do
    File.mkdir_p!(@results_dir)
    
    benchmarks = case benchmark do
      :all -> [:memory_search, :vector_math, :semantic_query, :port_spawn, :mcp_protocol]
      name when is_atom(name) -> [name]
      list when is_list(list) -> list
    end

    results = Enum.map(benchmarks, fn name ->
      Logger.info("Running benchmark: #{name}")
      {name, run_benchmark(name)}
    end)

    save_results(results)
    print_summary(results)
    results
  end

  # ==========================================================================
  # Memory Search Benchmark
  # ==========================================================================

  defp run_benchmark(:memory_search) do
    # Setup: Create test memories
    memories = generate_test_memories(1000)
    query = "test query for benchmark"

    scenarios = [
      {"100 memories", Enum.take(memories, 100)},
      {"500 memories", Enum.take(memories, 500)},
      {"1000 memories", memories}
    ]

    Enum.map(scenarios, fn {name, data} ->
      {time_us, _result} = :timer.tc(fn ->
        search_memories(query, data)
      end)
      
      {name, %{
        time_ms: time_us / 1000,
        memory_count: length(data),
        ops_per_sec: 1_000_000 / time_us
      }}
    end)
  end

  # ==========================================================================
  # Vector Math Benchmark
  # ==========================================================================

  defp run_benchmark(:vector_math) do
    dim = 768
    vec_a = for _ <- 1..dim, do: :rand.uniform()
    vec_b = for _ <- 1..dim, do: :rand.uniform()
    iterations = 1000

    # Benchmark NIF
    {nif_time, _} = :timer.tc(fn ->
      for _ <- 1..iterations do
        Mimo.Vector.Math.cosine_similarity(vec_a, vec_b)
      end
    end)

    # Benchmark pure Elixir fallback
    {elixir_time, _} = :timer.tc(fn ->
      for _ <- 1..iterations do
        cosine_similarity_elixir(vec_a, vec_b)
      end
    end)

    [
      {"NIF (Rust)", %{
        total_ms: nif_time / 1000,
        per_op_us: nif_time / iterations,
        ops_per_sec: iterations * 1_000_000 / nif_time
      }},
      {"Pure Elixir", %{
        total_ms: elixir_time / 1000,
        per_op_us: elixir_time / iterations,
        ops_per_sec: iterations * 1_000_000 / elixir_time
      }},
      {"Speedup", %{
        ratio: Float.round(elixir_time / nif_time, 2)
      }}
    ]
  end

  # ==========================================================================
  # Semantic Query Benchmark
  # ==========================================================================

  defp run_benchmark(:semantic_query) do
    # This benchmark uses available Query functions
    scenarios = [
      {"Pattern match (single clause)", fn -> 
        Mimo.SemanticStore.Query.pattern_match([{:any, "has_type", "entity"}])
      end},
      {"Transitive closure (1-hop)", fn ->
        Mimo.SemanticStore.Query.transitive_closure("root", "entity", "related_to", max_depth: 1)
      end},
      {"Find path", fn ->
        Mimo.SemanticStore.Query.find_path("start", "end", "connects_to", max_depth: 3)
      end}
    ]

    Enum.map(scenarios, fn {name, query_fn} ->
      times = for _ <- 1..10 do
        {time_us, _} = :timer.tc(query_fn)
        time_us
      end

      avg_time = Enum.sum(times) / length(times)
      min_time = Enum.min(times)
      max_time = Enum.max(times)

      {name, %{
        avg_ms: Float.round(avg_time / 1000, 2),
        min_ms: Float.round(min_time / 1000, 2),
        max_ms: Float.round(max_time / 1000, 2),
        ops_per_sec: Float.round(1_000_000 / avg_time, 1)
      }}
    end)
  end

  # ==========================================================================
  # Port Spawn Benchmark
  # ==========================================================================

  defp run_benchmark(:port_spawn) do
    iterations = 10

    times = for _ <- 1..iterations do
      {time_us, port} = :timer.tc(fn ->
        Port.open({:spawn, "echo hello"}, [:binary])
      end)
      Port.close(port)
      time_us
    end

    avg_time = Enum.sum(times) / length(times)

    [
      {"Port.open (echo)", %{
        avg_ms: Float.round(avg_time / 1000, 2),
        min_ms: Float.round(Enum.min(times) / 1000, 2),
        max_ms: Float.round(Enum.max(times) / 1000, 2),
        iterations: iterations
      }}
    ]
  end

  # ==========================================================================
  # MCP Protocol Benchmark
  # ==========================================================================

  defp run_benchmark(:mcp_protocol) do
    iterations = 1000

    # Benchmark JSON parsing
    sample_request = ~s({"jsonrpc":"2.0","method":"tools/call","params":{"name":"test","arguments":{"query":"hello"}},"id":1})
    
    {parse_time, _} = :timer.tc(fn ->
      for _ <- 1..iterations do
        Mimo.Protocol.McpParser.parse_line(sample_request)
      end
    end)

    # Benchmark response serialization
    sample_response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"content" => [%{"type" => "text", "text" => "Hello world"}]}}
    
    {serialize_time, _} = :timer.tc(fn ->
      for _ <- 1..iterations do
        Jason.encode!(sample_response)
      end
    end)

    [
      {"Parse request", %{
        total_ms: Float.round(parse_time / 1000, 2),
        per_op_us: Float.round(parse_time / iterations, 2),
        ops_per_sec: round(iterations * 1_000_000 / parse_time)
      }},
      {"Serialize response", %{
        total_ms: Float.round(serialize_time / 1000, 2),
        per_op_us: Float.round(serialize_time / iterations, 2),
        ops_per_sec: round(iterations * 1_000_000 / serialize_time)
      }}
    ]
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp generate_test_memories(count) do
    for i <- 1..count do
      %{
        id: i,
        content: "Test memory content #{i} with some additional text for embedding",
        category: Enum.random(["episodic", "semantic", "procedural"]),
        importance: :rand.uniform(),
        embedding: for(_ <- 1..768, do: :rand.uniform() * 2 - 1)
      }
    end
  end

  defp search_memories(query, memories) do
    # Simulate memory search with cosine similarity
    query_embedding = for _ <- 1..768, do: :rand.uniform() * 2 - 1
    
    memories
    |> Enum.map(fn m ->
      sim = cosine_similarity_elixir(query_embedding, m.embedding)
      {sim, m}
    end)
    |> Enum.sort_by(fn {sim, _} -> -sim end)
    |> Enum.take(10)
  end

  defp cosine_similarity_elixir(vec_a, vec_b) do
    dot = Enum.zip(vec_a, vec_b) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    norm_a = :math.sqrt(Enum.map(vec_a, &(&1 * &1)) |> Enum.sum())
    norm_b = :math.sqrt(Enum.map(vec_b, &(&1 * &1)) |> Enum.sum())
    dot / (norm_a * norm_b)
  end

  defp save_results(results) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\-]/, "")
    filename = Path.join(@results_dir, "benchmark_#{timestamp}.json")
    
    # Convert tuples to maps for JSON serialization
    results_map = results
    |> Enum.map(fn {benchmark_name, scenarios} ->
      scenarios_map = Enum.map(scenarios, fn {name, metrics} -> 
        {name, metrics}
      end)
      |> Map.new()
      {to_string(benchmark_name), scenarios_map}
    end)
    |> Map.new()
    
    data = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      system: %{
        otp_version: :erlang.system_info(:otp_release) |> to_string(),
        elixir_version: System.version(),
        schedulers: :erlang.system_info(:schedulers_online)
      },
      results: results_map
    }

    File.write!(filename, Jason.encode!(data, pretty: true))
    Logger.info("Results saved to #{filename}")
  end

  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("BENCHMARK SUMMARY")
    IO.puts(String.duplicate("=", 60))

    for {benchmark, scenarios} <- results do
      IO.puts("\n#{benchmark}:")
      IO.puts(String.duplicate("-", 40))
      
      for {name, metrics} <- scenarios do
        metrics_str = metrics
          |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
          |> Enum.join(", ")
        IO.puts("  #{name}: #{metrics_str}")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 60))
  end
end
