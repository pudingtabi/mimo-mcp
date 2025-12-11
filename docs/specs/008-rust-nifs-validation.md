# SPEC-008: Rust NIFs Production Validation

## Overview

**Goal**: Prove Rust NIFs for vector math are production-ready and provide measurable performance gains.

**Current Status**: ⚠️ Requires Build  
**Target Status**: ✅ Production Ready (with fallback)

## Production Readiness Criteria

### 1. Functional Completeness

| Feature | Required | Current | Test Coverage |
|---------|----------|---------|---------------|
| Cosine similarity | ✅ | ✅ | Needs validation |
| Batch similarity | ✅ | ✅ | Needs validation |
| Top-K search | ✅ | ✅ | Needs validation |
| Elixir fallback | ✅ | ✅ | Needs validation |
| Auto-detection | ✅ | ✅ | Needs validation |

### 2. Performance Benchmarks

| Operation | Elixir Baseline | Rust Target | Speedup Target |
|-----------|-----------------|-------------|----------------|
| Single cosine (768d) | ~500μs | < 50μs | 10x |
| Batch 100 vectors | ~50ms | < 5ms | 10x |
| Top-10 from 1000 | ~500ms | < 50ms | 10x |
| Top-10 from 10000 | ~5s | < 500ms | 10x |

### 3. Platform Support

| Platform | Status | Test Method |
|----------|--------|-------------|
| Linux x86_64 | Required | CI build |
| Linux ARM64 | Optional | Cross-compile |
| macOS x86_64 | Required | Local build |
| macOS ARM64 | Required | Local build |
| Windows | Optional | Cross-compile |

### 4. Safety Requirements

- [ ] No memory leaks
- [ ] No crashes on invalid input
- [ ] Graceful fallback if NIF fails to load
- [ ] Thread-safe for BEAM schedulers

---

## Test Implementation

### Task 1: NIF Loading Tests

**File**: `test/mimo/vector/math_test.exs`

```elixir
defmodule Mimo.Vector.MathTest do
  use ExUnit.Case, async: true
  
  alias Mimo.Vector.Math

  describe "nif_loaded?/0" do
    test "returns boolean indicating NIF status" do
      result = Math.nif_loaded?()
      assert is_boolean(result)
    end
  end

  describe "implementation/0" do
    test "returns :rust or :elixir" do
      impl = Math.implementation()
      assert impl in [:rust, :elixir]
    end
  end

  describe "cosine_similarity/2" do
    test "calculates similarity between identical vectors" do
      vec = List.duplicate(1.0, 768)
      
      {:ok, similarity} = Math.cosine_similarity(vec, vec)
      
      assert_in_delta similarity, 1.0, 0.0001
    end

    test "calculates similarity between orthogonal vectors" do
      vec_a = [1.0, 0.0, 0.0]
      vec_b = [0.0, 1.0, 0.0]
      
      {:ok, similarity} = Math.cosine_similarity(vec_a, vec_b)
      
      assert_in_delta similarity, 0.0, 0.0001
    end

    test "calculates similarity between opposite vectors" do
      vec_a = [1.0, 0.0, 0.0]
      vec_b = [-1.0, 0.0, 0.0]
      
      {:ok, similarity} = Math.cosine_similarity(vec_a, vec_b)
      
      assert_in_delta similarity, -1.0, 0.0001
    end

    test "handles mismatched dimensions" do
      vec_a = [1.0, 2.0, 3.0]
      vec_b = [1.0, 2.0]
      
      result = Math.cosine_similarity(vec_a, vec_b)
      
      assert {:error, :dimension_mismatch} = result
    end

    test "handles empty vectors" do
      result = Math.cosine_similarity([], [])
      
      assert {:error, _} = result
    end

    test "handles zero vectors" do
      zero = [0.0, 0.0, 0.0]
      other = [1.0, 2.0, 3.0]
      
      result = Math.cosine_similarity(zero, other)
      
      # Should handle gracefully (NaN or error)
      assert match?({:ok, _} | {:error, _}, result)
    end
  end

  describe "batch_similarity/2" do
    test "calculates similarity against multiple vectors" do
      query = [1.0, 0.0, 0.0]
      corpus = [
        [1.0, 0.0, 0.0],   # identical
        [0.0, 1.0, 0.0],   # orthogonal
        [0.5, 0.5, 0.0]    # 45 degrees
      ]
      
      {:ok, similarities} = Math.batch_similarity(query, corpus)
      
      assert length(similarities) == 3
      assert_in_delta Enum.at(similarities, 0), 1.0, 0.001
      assert_in_delta Enum.at(similarities, 1), 0.0, 0.001
    end

    test "handles empty corpus" do
      query = [1.0, 0.0, 0.0]
      
      {:ok, similarities} = Math.batch_similarity(query, [])
      
      assert similarities == []
    end
  end

  describe "top_k_similar/3" do
    test "returns top k most similar vectors" do
      query = [1.0, 0.0, 0.0]
      corpus = [
        {0, [0.9, 0.1, 0.0]},   # very similar
        {1, [0.0, 1.0, 0.0]},   # orthogonal
        {2, [0.8, 0.2, 0.0]},   # similar
        {3, [-1.0, 0.0, 0.0]},  # opposite
        {4, [0.7, 0.3, 0.0]}    # somewhat similar
      ]
      
      {:ok, results} = Math.top_k_similar(query, corpus, 3)
      
      assert length(results) == 3
      # Should be sorted by similarity descending
      [first, second, third] = results
      assert first.id == 0
      assert second.id == 2
      assert third.id == 4
    end

    test "handles k larger than corpus" do
      query = [1.0, 0.0, 0.0]
      corpus = [{0, [1.0, 0.0, 0.0]}, {1, [0.0, 1.0, 0.0]}]
      
      {:ok, results} = Math.top_k_similar(query, corpus, 10)
      
      assert length(results) == 2
    end
  end
end
```

### Task 2: Fallback Tests

**File**: `test/mimo/vector/fallback_test.exs`

```elixir
defmodule Mimo.Vector.FallbackTest do
  use ExUnit.Case, async: true
  
  alias Mimo.Vector.{Math, ElixirFallback}

  describe "ElixirFallback" do
    test "produces same results as NIF for cosine_similarity" do
      vec_a = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      vec_b = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      
      {:ok, elixir_result} = ElixirFallback.cosine_similarity(vec_a, vec_b)
      
      # If NIF loaded, compare results
      if Math.nif_loaded?() do
        {:ok, nif_result} = Math.cosine_similarity_nif(vec_a, vec_b)
        assert_in_delta elixir_result, nif_result, 0.0001
      end
    end

    test "produces same results for batch_similarity" do
      query = for _ <- 1..768, do: :rand.uniform() * 2 - 1
      corpus = for _ <- 1..100, do: (for _ <- 1..768, do: :rand.uniform() * 2 - 1)
      
      {:ok, elixir_results} = ElixirFallback.batch_similarity(query, corpus)
      
      if Math.nif_loaded?() do
        {:ok, nif_results} = Math.batch_similarity_nif(query, corpus)
        
        for {e, n} <- Enum.zip(elixir_results, nif_results) do
          assert_in_delta e, n, 0.0001
        end
      end
    end
  end

  describe "automatic fallback" do
    test "Math module works regardless of NIF status" do
      vec_a = [1.0, 2.0, 3.0]
      vec_b = [4.0, 5.0, 6.0]
      
      # Should always succeed, using NIF or fallback
      assert {:ok, _} = Math.cosine_similarity(vec_a, vec_b)
    end
  end
end
```

### Task 3: Performance Benchmarks

**File**: `bench/vector_math_bench.exs`

```elixir
defmodule VectorMathBench do
  alias Mimo.Vector.{Math, ElixirFallback}

  @dim 768  # Standard embedding dimension
  @sizes [100, 1000, 10_000]

  def run do
    IO.puts("=== Vector Math Benchmarks ===")
    IO.puts("Implementation: #{Math.implementation()}")
    IO.puts("NIF loaded: #{Math.nif_loaded?()}\n")
    
    bench_single_cosine()
    bench_batch_similarity()
    bench_top_k()
    compare_implementations()
  end

  defp bench_single_cosine do
    IO.puts("## Single Cosine Similarity (#{@dim}D)")
    
    vec_a = random_vector(@dim)
    vec_b = random_vector(@dim)
    
    # Elixir baseline
    {elixir_time, _} = :timer.tc(fn ->
      for _ <- 1..1000, do: ElixirFallback.cosine_similarity(vec_a, vec_b)
    end)
    elixir_avg = elixir_time / 1000
    
    # Current implementation (NIF or fallback)
    {impl_time, _} = :timer.tc(fn ->
      for _ <- 1..1000, do: Math.cosine_similarity(vec_a, vec_b)
    end)
    impl_avg = impl_time / 1000
    
    speedup = elixir_avg / impl_avg
    
    IO.puts("Elixir: #{Float.round(elixir_avg, 1)}μs")
    IO.puts("Current (#{Math.implementation()}): #{Float.round(impl_avg, 1)}μs")
    IO.puts("Speedup: #{Float.round(speedup, 1)}x")
    IO.puts("Target: 10x speedup with Rust")
    IO.puts("Status: #{status(speedup, 10)}\n")
  end

  defp bench_batch_similarity do
    IO.puts("## Batch Similarity")
    
    query = random_vector(@dim)
    
    for size <- @sizes do
      corpus = for _ <- 1..size, do: random_vector(@dim)
      
      {time, _} = :timer.tc(fn ->
        Math.batch_similarity(query, corpus)
      end)
      
      time_ms = time / 1000
      target = size / 20  # 50μs per vector target
      
      IO.puts("#{size} vectors: #{Float.round(time_ms, 1)}ms (target: < #{target}ms)")
    end
    IO.puts("")
  end

  defp bench_top_k do
    IO.puts("## Top-K Search")
    
    query = random_vector(@dim)
    k = 10
    
    for size <- @sizes do
      corpus = for i <- 1..size, do: {i, random_vector(@dim)}
      
      {time, {:ok, results}} = :timer.tc(fn ->
        Math.top_k_similar(query, corpus, k)
      end)
      
      time_ms = time / 1000
      target = size / 20
      
      IO.puts("Top-#{k} from #{size}: #{Float.round(time_ms, 1)}ms (target: < #{target}ms)")
      IO.puts("  Results: #{length(results)} items")
    end
    IO.puts("")
  end

  defp compare_implementations do
    IO.puts("## Implementation Comparison")
    
    if Math.nif_loaded?() do
      query = random_vector(@dim)
      corpus = for _ <- 1..1000, do: random_vector(@dim)
      
      {elixir_time, _} = :timer.tc(fn ->
        ElixirFallback.batch_similarity(query, corpus)
      end)
      
      {nif_time, _} = :timer.tc(fn ->
        Math.batch_similarity(query, corpus)
      end)
      
      speedup = elixir_time / nif_time
      
      IO.puts("1000 vectors batch:")
      IO.puts("  Elixir: #{Float.round(elixir_time/1000, 1)}ms")
      IO.puts("  Rust NIF: #{Float.round(nif_time/1000, 1)}ms")
      IO.puts("  Speedup: #{Float.round(speedup, 1)}x")
    else
      IO.puts("NIF not loaded - comparison skipped")
      IO.puts("Build NIF with: cd native/vector_math && cargo build --release")
    end
  end

  defp random_vector(dim) do
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end

  defp status(actual, target) when actual >= target, do: "✅ PASS"
  defp status(_, _), do: "❌ FAIL (NIF may not be loaded)"
end

# Run with: mix run bench/vector_math_bench.exs
VectorMathBench.run()
```

### Task 4: Build & Integration Tests

**File**: `test/integration/rust_nif_integration_test.exs`

```elixir
defmodule Mimo.Integration.RustNifIntegrationTest do
  use ExUnit.Case
  
  @moduletag :integration

  alias Mimo.Vector.Math

  describe "NIF build verification" do
    @tag :requires_rust
    test "NIF can be loaded after build" do
      # This test only runs if Rust is available
      case System.cmd("cargo", ["--version"], stderr_to_stdout: true) do
        {_, 0} ->
          # Build NIF
          {_, 0} = System.cmd("cargo", ["build", "--release"],
            cd: "native/vector_math",
            stderr_to_stdout: true
          )
          
          # Reload and check
          :code.purge(Mimo.Vector.MathNif)
          :code.delete(Mimo.Vector.MathNif)
          
          assert Math.nif_loaded?()
          
        _ ->
          IO.puts("Skipping: Rust not available")
      end
    end
  end

  describe "memory safety" do
    test "handles large vectors without crash" do
      # 4096 dimensions (larger than typical)
      vec_a = for _ <- 1..4096, do: :rand.uniform()
      vec_b = for _ <- 1..4096, do: :rand.uniform()
      
      # Should not crash
      assert {:ok, _} = Math.cosine_similarity(vec_a, vec_b)
    end

    test "handles many sequential calls" do
      vec = for _ <- 1..768, do: :rand.uniform()
      
      # 10000 calls should not cause memory issues
      for _ <- 1..10_000 do
        Math.cosine_similarity(vec, vec)
      end
      
      # If we get here, no crash
      assert true
    end

    test "handles concurrent calls" do
      vec = for _ <- 1..768, do: :rand.uniform()
      
      tasks = for _ <- 1..100 do
        Task.async(fn ->
          for _ <- 1..100 do
            Math.cosine_similarity(vec, vec)
          end
        end)
      end
      
      # All should complete without crash
      Task.await_many(tasks, 30_000)
      assert true
    end
  end
end
```

---

## Build Instructions

### Prerequisites

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# Verify
rustc --version
cargo --version
```

### Build NIF

```bash
cd native/vector_math
cargo build --release

# Copy to priv (if not automatic)
cp target/release/libvector_math.so ../../priv/native/
```

### Verify

```elixir
iex -S mix

Mimo.Vector.Math.nif_loaded?()
# => true

Mimo.Vector.Math.implementation()
# => :rust
```

---

## Acceptance Criteria

### Must Pass for ✅ Production Ready

1. **Correctness**: All math operations produce correct results
2. **Fallback**: Elixir fallback works when NIF not loaded
3. **Performance**: 10x speedup over Elixir (when NIF loaded)
4. **Safety**: No crashes, memory leaks, or race conditions
5. **Build**: Documented build process works

### Status Levels

| Status | Meaning |
|--------|---------|
| ✅ Production Ready | NIF loaded, all tests pass, 10x speedup |
| ⚠️ Fallback Mode | NIF not loaded, using Elixir (functional but slower) |
| ❌ Broken | Tests failing |

---

## Agent Prompt

```markdown
# Rust NIF Validation Agent

## Mission
Validate Rust NIFs are production-ready OR confirm fallback works correctly.

## Tasks
1. Check if NIF is currently loaded
2. If not, attempt to build (if Rust available)
3. Run all correctness tests
4. Run performance benchmarks
5. Document results

## Success Criteria
Option A (Full): NIF loaded, 10x speedup, all tests pass
Option B (Fallback): Fallback works, tests pass, documented as "requires build"

## Output
Validation report with:
- NIF load status
- Test results
- Benchmark numbers
- Build instructions (if NIF not loaded)
- Recommendation
```
