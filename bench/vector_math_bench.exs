defmodule VectorMathBench do
  @moduledoc """
  SPEC-008: Rust NIFs Performance Benchmarks

  Benchmarks for validating Rust NIF performance targets:
  - Single cosine similarity: 10x speedup over Elixir
  - Batch operations: 10x speedup
  - Top-K search: 10x speedup

  Run with: mix run bench/vector_math_bench.exs
  """

  alias Mimo.Vector.Math
  alias Mimo.Vector.Fallback

  @dim_384 384
  @dim_768 768
  @dim_1536 1536
  @sizes [100, 1000, 10_000]
  @iterations 1000

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("    SPEC-008: Rust NIFs Performance Validation Benchmark")
    IO.puts(String.duplicate("=", 70))
    IO.puts("NIF Loaded: #{Math.nif_loaded?()}")
    IO.puts("Date: #{DateTime.utc_now() |> DateTime.to_string()}")
    IO.puts(String.duplicate("=", 70) <> "\n")

    results = %{
      single_cosine: bench_single_cosine(),
      batch_similarity: bench_batch_similarity(),
      top_k_search: bench_top_k(),
      dimension_scaling: bench_dimension_scaling()
    }

    generate_summary(results)
    results
  end

  # ===========================================================================
  # Single Cosine Similarity Benchmark
  # ===========================================================================

  defp bench_single_cosine do
    IO.puts("## Single Cosine Similarity Benchmark")
    IO.puts(String.duplicate("-", 50))

    results =
      for dim <- [@dim_384, @dim_768, @dim_1536] do
        vec_a = random_vector(dim)
        vec_b = random_vector(dim)

        # Elixir fallback baseline
        {elixir_time, _} =
          :timer.tc(fn ->
            for _ <- 1..@iterations, do: Fallback.cosine_similarity(vec_a, vec_b)
          end)

        elixir_avg = elixir_time / @iterations

        # Current implementation (NIF if loaded, fallback otherwise)
        {impl_time, _} =
          :timer.tc(fn ->
            for _ <- 1..@iterations, do: Math.cosine_similarity(vec_a, vec_b)
          end)

        impl_avg = impl_time / @iterations
        speedup = elixir_avg / impl_avg

        IO.puts("\n  #{dim}-dimensional vectors:")
        IO.puts("    Elixir fallback: #{format_time(elixir_avg)}")
        IO.puts("    Current (#{impl_type()}): #{format_time(impl_avg)}")
        IO.puts("    Speedup: #{Float.round(speedup, 2)}x")
        IO.puts("    Target: 10x | Status: #{status(speedup, 10)}")

        %{
          dimension: dim,
          elixir_us: elixir_avg,
          impl_us: impl_avg,
          speedup: speedup,
          pass: speedup >= 10
        }
      end

    IO.puts("\n")
    results
  end

  # ===========================================================================
  # Batch Similarity Benchmark
  # ===========================================================================

  defp bench_batch_similarity do
    IO.puts("## Batch Similarity Benchmark (768-dim)")
    IO.puts(String.duplicate("-", 50))

    query = random_vector(@dim_768)

    results =
      for size <- @sizes do
        corpus = for _ <- 1..size, do: random_vector(@dim_768)

        # Elixir fallback
        {elixir_time, _} =
          :timer.tc(fn ->
            Fallback.batch_similarity(query, corpus)
          end)

        elixir_ms = elixir_time / 1000

        # Current implementation
        {impl_time, _} =
          :timer.tc(fn ->
            Math.batch_similarity(query, corpus)
          end)

        impl_ms = impl_time / 1000
        speedup = elixir_time / impl_time
        target_ms = size / 20

        IO.puts("\n  #{size} vectors:")
        IO.puts("    Elixir fallback: #{Float.round(elixir_ms, 2)}ms")
        IO.puts("    Current (#{impl_type()}): #{Float.round(impl_ms, 2)}ms")
        IO.puts("    Speedup: #{Float.round(speedup, 2)}x")
        IO.puts("    Target: < #{Float.round(target_ms, 1)}ms | Status: #{status(impl_ms <= target_ms or speedup >= 10)}")

        %{
          corpus_size: size,
          elixir_ms: elixir_ms,
          impl_ms: impl_ms,
          speedup: speedup,
          pass: speedup >= 10
        }
      end

    IO.puts("\n")
    results
  end

  # ===========================================================================
  # Top-K Search Benchmark
  # ===========================================================================

  defp bench_top_k do
    IO.puts("## Top-K Search Benchmark (768-dim, k=10)")
    IO.puts(String.duplicate("-", 50))

    query = random_vector(@dim_768)
    k = 10

    results =
      for size <- @sizes do
        corpus = for _ <- 1..size, do: random_vector(@dim_768)

        # Elixir fallback
        {elixir_time, _} =
          :timer.tc(fn ->
            Fallback.top_k_similar(query, corpus, k)
          end)

        elixir_ms = elixir_time / 1000

        # Current implementation
        {impl_time, {:ok, results}} =
          :timer.tc(fn ->
            Math.top_k_similar(query, corpus, k)
          end)

        impl_ms = impl_time / 1000
        speedup = elixir_time / impl_time
        target_ms = size / 20

        IO.puts("\n  Top-#{k} from #{size} vectors:")
        IO.puts("    Elixir fallback: #{Float.round(elixir_ms, 2)}ms")
        IO.puts("    Current (#{impl_type()}): #{Float.round(impl_ms, 2)}ms")
        IO.puts("    Speedup: #{Float.round(speedup, 2)}x")
        IO.puts("    Results returned: #{length(results)}")
        IO.puts("    Target: < #{Float.round(target_ms, 1)}ms | Status: #{status(impl_ms <= target_ms or speedup >= 10)}")

        %{
          corpus_size: size,
          k: k,
          elixir_ms: elixir_ms,
          impl_ms: impl_ms,
          speedup: speedup,
          pass: speedup >= 10
        }
      end

    IO.puts("\n")
    results
  end

  # ===========================================================================
  # Dimension Scaling Benchmark
  # ===========================================================================

  defp bench_dimension_scaling do
    IO.puts("## Dimension Scaling Benchmark (1000 vectors)")
    IO.puts(String.duplicate("-", 50))

    results =
      for dim <- [@dim_384, @dim_768, @dim_1536] do
        query = random_vector(dim)
        corpus = for _ <- 1..1000, do: random_vector(dim)

        # Current implementation
        {impl_time, _} =
          :timer.tc(fn ->
            Math.batch_similarity(query, corpus)
          end)

        impl_ms = impl_time / 1000

        IO.puts("\n  #{dim}-dimensional:")
        IO.puts("    Time: #{Float.round(impl_ms, 2)}ms")
        IO.puts("    Per-vector: #{Float.round(impl_time / 1000, 2)}μs")

        %{
          dimension: dim,
          total_ms: impl_ms,
          per_vector_us: impl_time / 1000
        }
      end

    IO.puts("\n")
    results
  end

  # ===========================================================================
  # Summary Generation
  # ===========================================================================

  defp generate_summary(results) do
    IO.puts(String.duplicate("=", 70))
    IO.puts("                        SUMMARY")
    IO.puts(String.duplicate("=", 70))

    single_pass =
      results.single_cosine
      |> Enum.filter(& &1.pass)
      |> length()

    batch_pass =
      results.batch_similarity
      |> Enum.filter(& &1.pass)
      |> length()

    topk_pass =
      results.top_k_search
      |> Enum.filter(& &1.pass)
      |> length()

    total_tests = length(@sizes) * 2 + 3
    total_pass = single_pass + batch_pass + topk_pass

    IO.puts("\n  Test Results:")
    IO.puts("    Single Cosine: #{single_pass}/3 passing 10x target")
    IO.puts("    Batch Similarity: #{batch_pass}/#{length(@sizes)} passing 10x target")
    IO.puts("    Top-K Search: #{topk_pass}/#{length(@sizes)} passing 10x target")
    IO.puts("")
    IO.puts("  Overall: #{total_pass}/#{total_tests} tests meeting 10x speedup target")

    avg_speedup =
      (Enum.map(results.single_cosine, & &1.speedup) ++
         Enum.map(results.batch_similarity, & &1.speedup) ++
         Enum.map(results.top_k_search, & &1.speedup))
      |> Enum.sum()
      |> Kernel./(total_tests)

    IO.puts("  Average Speedup: #{Float.round(avg_speedup, 2)}x")

    overall_status =
      if Math.nif_loaded?() and avg_speedup >= 10 do
        "✅ PRODUCTION READY"
      else
        if Math.nif_loaded?() do
          "⚠️ NIF LOADED BUT BELOW TARGET"
        else
          "⚠️ FALLBACK MODE (NIF not loaded)"
        end
      end

    IO.puts("\n  Status: #{overall_status}")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp random_vector(dim) do
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end

  defp impl_type do
    if Math.nif_loaded?(), do: "Rust NIF", else: "Elixir"
  end

  defp format_time(us) when us < 1000, do: "#{Float.round(us, 2)}μs"
  defp format_time(us), do: "#{Float.round(us / 1000, 2)}ms"

  defp status(actual, target) when is_number(actual) and is_number(target) do
    if actual >= target, do: "✅ PASS", else: "❌ FAIL"
  end

  defp status(true), do: "✅ PASS"
  defp status(false), do: "❌ FAIL"
end

# Run benchmark
VectorMathBench.run()
