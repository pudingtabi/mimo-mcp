# Mimo MCP Benchmark Runner
# Usage: mix run bench/runner.exs

# Compile the benchmark module
Code.compile_file("bench/benchmark.ex")

# Run all benchmarks
IO.puts("Starting Mimo MCP Benchmark Suite...")
IO.puts("=" |> String.duplicate(60))

results = Mimo.Bench.run(:all)

IO.puts("\nBenchmark complete!")
IO.puts("Results saved to bench/results/")
