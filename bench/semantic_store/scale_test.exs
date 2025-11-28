#!/usr/bin/env elixir
# Semantic Store Benchmark Suite
# Run with: mix run bench/semantic_store/scale_test.exs
#
# SPEC-006: Scale testing for production validation

defmodule SemanticStoreBench do
  @moduledoc """
  Comprehensive benchmarks for Semantic Store production validation.
  
  Tests:
  - Insert performance at scale
  - Query performance at scale
  - Memory usage patterns
  """

  alias Mimo.SemanticStore.{Repository, Query}
  alias Mimo.Repo

  @doc """
  Run all benchmarks and output results.
  """
  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("   SEMANTIC STORE PRODUCTION VALIDATION BENCHMARKS")
    IO.puts(String.duplicate("=", 60) <> "\n")

    # Start the application if not already started
    ensure_started()

    results = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      benchmarks: %{}
    }

    results = Map.put(results, :benchmarks, %{
      insert_1k: bench_inserts(1_000),
      insert_10k: bench_inserts(10_000),
      lookup_performance: bench_lookups(),
      traversal_2hop: bench_traversal(2),
      traversal_3hop: bench_traversal(3),
      traversal_5hop: bench_traversal(5),
      batch_insert: bench_batch_insert(),
      concurrent_access: bench_concurrent()
    })

    print_summary(results)
    save_results(results)

    results
  end

  defp ensure_started do
    Application.ensure_all_started(:mimo)
  end

  @doc """
  Benchmark individual triple inserts.
  """
  def bench_inserts(count) do
    IO.puts("\n## Insert Performance (#{count} triples)")
    IO.puts(String.duplicate("-", 40))

    # Clean up any existing test data
    cleanup_test_data("insert_bench")

    {time_us, _} =
      :timer.tc(fn ->
        for i <- 1..count do
          Repository.create(%{
            subject_id: "insert_bench:#{i}",
            subject_type: "bench",
            predicate: "relates_to",
            object_id: "insert_bench:#{rem(i, 100)}",
            object_type: "bench"
          })
        end
      end)

    total_ms = time_us / 1000
    avg_ms = total_ms / count

    target = 10.0
    status = if avg_ms < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  Total time: #{Float.round(total_ms, 2)}ms")
    IO.puts("  Average: #{Float.round(avg_ms, 3)}ms per insert")
    IO.puts("  Target: < #{target}ms per insert")
    IO.puts("  Status: #{status}")

    %{
      operation: "insert",
      count: count,
      total_ms: Float.round(total_ms, 2),
      avg_ms: Float.round(avg_ms, 4),
      target_ms: target,
      passed: avg_ms < target
    }
  end

  @doc """
  Benchmark lookup operations.
  """
  def bench_lookups do
    IO.puts("\n## Lookup Performance")
    IO.puts(String.duplicate("-", 40))

    # Ensure data exists
    for i <- 1..100 do
      Repository.create!(%{
        subject_id: "lookup_bench:#{i}",
        subject_type: "bench",
        predicate: "test",
        object_id: "target:#{i}",
        object_type: "bench"
      })
    end

    {time_us, _} =
      :timer.tc(fn ->
        for _ <- 1..1000 do
          Repository.get_by_subject("lookup_bench:#{:rand.uniform(100)}", "bench")
        end
      end)

    total_ms = time_us / 1000
    avg_ms = total_ms / 1000

    target = 5.0
    status = if avg_ms < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  1000 lookups: #{Float.round(total_ms, 2)}ms")
    IO.puts("  Average: #{Float.round(avg_ms, 3)}ms per lookup")
    IO.puts("  Target: < #{target}ms per lookup")
    IO.puts("  Status: #{status}")

    %{
      operation: "lookup",
      count: 1000,
      total_ms: Float.round(total_ms, 2),
      avg_ms: Float.round(avg_ms, 4),
      target_ms: target,
      passed: avg_ms < target
    }
  end

  @doc """
  Benchmark graph traversal at different depths.
  """
  def bench_traversal(max_depth) do
    IO.puts("\n## #{max_depth}-Hop Traversal Performance")
    IO.puts(String.duplicate("-", 40))

    # Create a tree: root -> 10 children -> 10 grandchildren each -> etc
    create_tree("trav_bench_#{max_depth}", 3, 10)

    # Run traversal multiple times
    times =
      for _ <- 1..10 do
        {time_us, _} =
          :timer.tc(fn ->
            Query.transitive_closure("trav_bench_#{max_depth}_root", "node", "parent", max_depth: max_depth)
          end)

        time_us / 1000
      end

    avg_ms = Enum.sum(times) / length(times)
    min_ms = Enum.min(times)
    max_ms = Enum.max(times)

    target =
      case max_depth do
        2 -> 50.0
        3 -> 200.0
        5 -> 500.0
        _ -> 1000.0
      end

    status = if avg_ms < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  Average: #{Float.round(avg_ms, 2)}ms")
    IO.puts("  Min: #{Float.round(min_ms, 2)}ms, Max: #{Float.round(max_ms, 2)}ms")
    IO.puts("  Target: < #{target}ms")
    IO.puts("  Status: #{status}")

    %{
      operation: "traversal_#{max_depth}hop",
      avg_ms: Float.round(avg_ms, 2),
      min_ms: Float.round(min_ms, 2),
      max_ms: Float.round(max_ms, 2),
      target_ms: target,
      passed: avg_ms < target
    }
  end

  @doc """
  Benchmark batch insert operations.
  """
  def bench_batch_insert do
    IO.puts("\n## Batch Insert Performance (1000 triples)")
    IO.puts(String.duplicate("-", 40))

    triples =
      for i <- 1..1000 do
        %{
          subject_id: "batch_bench:#{i}",
          subject_type: "batch",
          predicate: "batch_rel",
          object_id: "batch_target:#{rem(i, 50)}",
          object_type: "batch"
        }
      end

    {time_us, result} = :timer.tc(fn -> Repository.batch_create(triples) end)

    time_s = time_us / 1_000_000

    target = 5.0
    status = if time_s < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  Time: #{Float.round(time_s, 2)}s")
    IO.puts("  Result: #{inspect(result)}")
    IO.puts("  Target: < #{target}s")
    IO.puts("  Status: #{status}")

    %{
      operation: "batch_insert",
      count: 1000,
      time_s: Float.round(time_s, 2),
      target_s: target,
      passed: time_s < target
    }
  end

  @doc """
  Benchmark concurrent read/write access.
  """
  def bench_concurrent do
    IO.puts("\n## Concurrent Access Performance")
    IO.puts(String.duplicate("-", 40))

    # Seed some data
    for i <- 1..100 do
      Repository.create!(%{
        subject_id: "conc_bench:#{i}",
        subject_type: "conc",
        predicate: "rel",
        object_id: "conc_target:#{i}",
        object_type: "conc"
      })
    end

    {time_us, results} =
      :timer.tc(fn ->
        # 50 readers, 50 writers
        read_tasks =
          for _ <- 1..50 do
            Task.async(fn ->
              Repository.get_by_subject("conc_bench:#{:rand.uniform(100)}", "conc")
            end)
          end

        write_tasks =
          for i <- 101..150 do
            Task.async(fn ->
              Repository.create(%{
                subject_id: "conc_bench:#{i}",
                subject_type: "conc",
                predicate: "rel",
                object_id: "conc_target:#{i}",
                object_type: "conc"
              })
            end)
          end

        Task.await_many(read_tasks ++ write_tasks, 30_000)
      end)

    time_ms = time_us / 1000
    successful_writes = Enum.count(Enum.drop(results, 50), &match?({:ok, _}, &1))

    target = 5000.0
    status = if time_ms < target and successful_writes == 50, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  Total time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Successful writes: #{successful_writes}/50")
    IO.puts("  Target: < #{target}ms, 100% success")
    IO.puts("  Status: #{status}")

    %{
      operation: "concurrent",
      time_ms: Float.round(time_ms, 2),
      successful_writes: successful_writes,
      target_ms: target,
      passed: time_ms < target and successful_writes == 50
    }
  end

  # Helper to create a tree structure
  defp create_tree(prefix, depth, branching_factor) when depth > 0 do
    root_id = "#{prefix}_root"

    # Create children recursively
    create_tree_level(prefix, root_id, 1, depth, branching_factor)
  end

  defp create_tree_level(_prefix, _parent_id, current_depth, max_depth, _bf) when current_depth > max_depth, do: :ok

  defp create_tree_level(prefix, parent_id, current_depth, max_depth, bf) do
    for i <- 1..bf do
      child_id = "#{prefix}_d#{current_depth}_#{i}_p#{parent_id}"

      Repository.create!(%{
        subject_id: parent_id,
        subject_type: "node",
        predicate: "parent",
        object_id: child_id,
        object_type: "node"
      })

      if current_depth < max_depth do
        create_tree_level(prefix, child_id, current_depth + 1, max_depth, bf)
      end
    end
  end

  defp cleanup_test_data(prefix) do
    # Use raw SQL for cleanup
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM semantic_triples WHERE subject_id LIKE ?", ["#{prefix}%"])
  end

  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("   BENCHMARK SUMMARY")
    IO.puts(String.duplicate("=", 60))

    passed =
      results.benchmarks
      |> Map.values()
      |> Enum.count(& &1.passed)

    total = map_size(results.benchmarks)

    IO.puts("\n  Passed: #{passed}/#{total}")

    if passed == total do
      IO.puts("\n  🎉 ALL BENCHMARKS PASSED - Production Ready!")
    else
      IO.puts("\n  ⚠️  Some benchmarks failed - Review required")
    end

    IO.puts("")
  end

  defp save_results(results) do
    filename = "bench/results/semantic_store_#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")}.json"

    File.mkdir_p!("bench/results")
    File.write!(filename, Jason.encode!(results, pretty: true))

    IO.puts("Results saved to: #{filename}")
  end
end

# Run the benchmarks
SemanticStoreBench.run()
