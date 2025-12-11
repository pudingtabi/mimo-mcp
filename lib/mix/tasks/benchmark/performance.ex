defmodule Mix.Tasks.Benchmark.Performance do
  @shortdoc "Run production performance benchmarks (SPEC-061)"
  @moduledoc """
  Run Mimo production performance benchmarks.

  ## Usage

      # Run all benchmarks with defaults
      mix benchmark.performance

      # Custom iterations
      mix benchmark.performance --iterations 1000

      # Custom concurrency
      mix benchmark.performance --concurrency 100

      # Include scale tests
      mix benchmark.performance --scale

      # Save results to JSON
      mix benchmark.performance --output results.json

      # Quick mode (fewer iterations)
      mix benchmark.performance --quick

  ## Options

    * `--iterations`, `-i` - Number of iterations for latency tests (default: 500)
    * `--concurrency`, `-c` - Number of concurrent workers (default: 50)
    * `--duration`, `-d` - Duration for concurrent test in ms (default: 10000)
    * `--scale`, `-s` - Include scale tests (100, 1K, 10K memories)
    * `--output`, `-o` - Save results to JSON file
    * `--quick`, `-q` - Quick mode with fewer iterations

  ## Exit Codes

    * 0 - All targets passed
    * 1 - One or more targets failed

  ## Targets (SPEC-061)

    * p95 Latency: < 1500ms (matches Mem0's 1.44s)
    * p99 Latency: < 3000ms
    * Throughput: > 100 req/s
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          iterations: :integer,
          concurrency: :integer,
          duration: :integer,
          scale: :boolean,
          output: :string,
          quick: :boolean
        ],
        aliases: [
          i: :iterations,
          c: :concurrency,
          d: :duration,
          s: :scale,
          o: :output,
          q: :quick
        ]
      )

    # Apply quick mode defaults
    opts =
      if opts[:quick] do
        Keyword.merge([iterations: 100, concurrency: 20, duration: 5000], opts)
      else
        opts
      end

    IO.puts("")
    IO.puts(banner())
    IO.puts("")

    # Build options
    bench_opts = [
      iterations: opts[:iterations] || 500,
      concurrency: opts[:concurrency] || 50,
      duration_ms: opts[:duration] || 10_000
    ]

    # Add scales if requested
    bench_opts =
      if opts[:scale] do
        Keyword.put(bench_opts, :scales, [100, 1_000, 10_000])
      else
        Keyword.put(bench_opts, :scales, [100, 500])
      end

    IO.puts("Configuration:")
    IO.puts("  Iterations: #{bench_opts[:iterations]}")
    IO.puts("  Concurrency: #{bench_opts[:concurrency]}")
    IO.puts("  Duration: #{bench_opts[:duration_ms]}ms")
    IO.puts("  Scales: #{inspect(bench_opts[:scales])}")
    IO.puts("")

    # Run benchmarks
    results = Mimo.Benchmark.Performance.run_all(bench_opts)

    # Print results
    print_results(results)

    # Save to file if requested
    if output = opts[:output] do
      save_results(results, output)
    end

    # Exit with appropriate code
    if results.targets.p95_pass and results.targets.throughput_pass do
      IO.puts(IO.ANSI.green() <> "\n✓ All targets PASSED" <> IO.ANSI.reset())
      System.stop(0)
    else
      IO.puts(IO.ANSI.red() <> "\n✗ Some targets FAILED" <> IO.ANSI.reset())
      System.stop(1)
    end
  end

  defp banner do
    """
    ╔══════════════════════════════════════════════════════════════════╗
    ║          MIMO PRODUCTION PERFORMANCE BENCHMARKS                  ║
    ║                     SPEC-061                                     ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║  Targets:                                                        ║
    ║    • p95 Latency: < 1500ms (Mem0: 1.44s, Zep: 2.58s)            ║
    ║    • p99 Latency: < 3000ms                                       ║
    ║    • Throughput: > 100 req/s                                     ║
    ╚══════════════════════════════════════════════════════════════════╝
    """
  end

  defp print_results(results) do
    IO.puts(String.duplicate("═", 70))
    IO.puts("SYSTEM INFO")
    IO.puts(String.duplicate("─", 70))
    sys = results.system
    IO.puts("  OTP: #{sys.otp_version} | Elixir: #{sys.elixir_version}")
    IO.puts("  Schedulers: #{sys.schedulers} | Memory: #{sys.memory_mb}MB")
    IO.puts("  Memory Count: #{sys.memory_count}")
    IO.puts("")

    IO.puts(String.duplicate("═", 70))
    IO.puts("LATENCY RESULTS")
    IO.puts(String.duplicate("─", 70))

    IO.puts("\nMEMORY SEARCH:")
    print_latencies(results.memory_search)

    IO.puts("\nMEMORY STORE:")
    print_latencies(results.memory_store)

    IO.puts("\nTOOL DISPATCH:")
    print_latencies(results.tool_dispatch)

    IO.puts("")
    IO.puts(String.duplicate("═", 70))
    IO.puts("CONCURRENT LOAD TEST")
    IO.puts(String.duplicate("─", 70))
    cl = results.concurrent_load
    IO.puts("  Workers: #{cl.concurrency}")
    IO.puts("  Duration: #{cl.duration_ms}ms")
    IO.puts("  Total Requests: #{cl.total_requests}")
    IO.puts("  Throughput: #{cl.throughput_rps} req/s")
    IO.puts("  Operations: search=#{cl.operations.search}, store=#{cl.operations.store}")
    IO.puts("\n  Latencies:")
    print_latencies(cl.latencies, "    ")

    IO.puts("")
    IO.puts(String.duplicate("═", 70))
    IO.puts("SCALE TEST")
    IO.puts(String.duplicate("─", 70))

    Enum.each(results.memory_at_scale, fn {count, latencies} ->
      count_str = format_count(count)

      IO.puts(
        "  #{count_str} memories: p50=#{latencies.p50}ms, p95=#{latencies.p95}ms, p99=#{latencies.p99}ms"
      )
    end)

    IO.puts("")
    IO.puts(String.duplicate("═", 70))
    IO.puts("TARGET COMPARISON")
    IO.puts(String.duplicate("─", 70))

    t = results.targets

    p95_status = status_icon(t.p95_pass)
    p99_status = status_icon(t.p99_pass)
    throughput_status = status_icon(t.throughput_pass)

    IO.puts("  #{p95_status} p95 Latency: #{t.p95_latency_ms}ms (target: <#{t.p95_target_ms}ms)")
    IO.puts("  #{p99_status} p99 Latency: #{t.p99_latency_ms}ms (target: <#{t.p99_target_ms}ms)")

    IO.puts(
      "  #{throughput_status} Throughput: #{t.throughput_rps} req/s (target: >#{t.throughput_target_rps})"
    )

    IO.puts(String.duplicate("═", 70))
  end

  defp print_latencies(l, prefix \\ "  ") do
    IO.puts("#{prefix}min: #{l.min}ms | avg: #{l.avg}ms | max: #{l.max}ms")
    IO.puts("#{prefix}p50: #{l.p50}ms | p90: #{l.p90}ms | p95: #{l.p95}ms | p99: #{l.p99}ms")
  end

  defp format_count(count) when count >= 1000, do: "#{div(count, 1000)}K"
  defp format_count(count), do: "#{count}"

  defp status_icon(true), do: IO.ANSI.green() <> "✓" <> IO.ANSI.reset()
  defp status_icon(false), do: IO.ANSI.red() <> "✗" <> IO.ANSI.reset()

  defp save_results(results, path) do
    json = Jason.encode!(results, pretty: true)
    File.write!(path, json)
    IO.puts("\nResults saved to: #{path}")
  end
end
