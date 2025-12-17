#!/usr/bin/env elixir
# Procedural Store Benchmark Suite
# Run with: mix run bench/procedural_store/concurrent_bench.exs
#
# SPEC-007: Performance validation for FSM engine

defmodule ProceduralStoreBench do
  @moduledoc """
  Comprehensive benchmarks for Procedural Store production validation.
  
  Tests:
  - Procedure registration performance
  - State transition speed
  - Full procedure execution time
  - Concurrent execution capability
  """

  alias Mimo.ProceduralStore.{ExecutionFSM, Loader}

  @doc """
  Run all benchmarks and output results.
  """
  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("   PROCEDURAL STORE PRODUCTION VALIDATION BENCHMARKS")
    IO.puts(String.duplicate("=", 60) <> "\n")

    # Start the application if not already started
    ensure_started()

    results = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      benchmarks: %{}
    }

    results = Map.put(results, :benchmarks, %{
      procedure_load: bench_procedure_load(),
      state_transitions: bench_state_transitions(),
      full_execution: bench_full_execution(),
      concurrent_10: bench_concurrent(10),
      concurrent_50: bench_concurrent(50)
    })

    print_summary(results)
    save_results(results)

    results
  end

  defp ensure_started do
    Application.ensure_all_started(:mimo)

    # Initialize loader cache
    try do
      Loader.init()
    catch
      :error, :badarg -> :ok
    end
  end

  @doc """
  Benchmark procedure registration.
  """
  def bench_procedure_load do
    IO.puts("\n## Procedure Load Performance")
    IO.puts(String.duplicate("-", 40))

    {time_us, _} =
      :timer.tc(fn ->
        for i <- 1..100 do
          Loader.register(%{
            name: "load_bench_#{i}",
            version: "1.0",
            definition: %{
              "initial_state" => "start",
              "states" => %{
                "start" => %{
                  "action" => %{
                    "module" => "Mimo.ProceduralStore.Steps.SetContext",
                    "function" => "execute",
                    "args" => [%{"values" => %{"loaded" => true}}]
                  },
                  "transitions" => [%{"event" => "success", "target" => "done"}]
                },
                "done" => %{}
              }
            }
          })
        end
      end)

    total_ms = time_us / 1000
    avg_ms = total_ms / 100

    target = 10.0
    status = if avg_ms < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  100 procedure registrations: #{Float.round(total_ms, 2)}ms")
    IO.puts("  Average: #{Float.round(avg_ms, 3)}ms per registration")
    IO.puts("  Target: < #{target}ms per registration")
    IO.puts("  Status: #{status}")

    %{
      operation: "procedure_load",
      count: 100,
      total_ms: Float.round(total_ms, 2),
      avg_ms: Float.round(avg_ms, 4),
      target_ms: target,
      passed: avg_ms < target
    }
  end

  @doc """
  Benchmark state transition speed.
  """
  def bench_state_transitions do
    IO.puts("\n## State Transition Performance")
    IO.puts(String.duplicate("-", 40))

    # Register a multi-state procedure
    {:ok, _} =
      Loader.register(%{
        name: "transition_bench",
        version: "1.0",
        definition: %{
          "initial_state" => "s1",
          "states" => %{
            "s1" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"s1" => true}}]
              },
              "transitions" => [%{"event" => "success", "target" => "s2"}]
            },
            "s2" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"s2" => true}}]
              },
              "transitions" => [%{"event" => "success", "target" => "s3"}]
            },
            "s3" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"s3" => true}}]
              },
              "transitions" => [%{"event" => "success", "target" => "s4"}]
            },
            "s4" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"s4" => true}}]
              },
              "transitions" => [%{"event" => "success", "target" => "s5"}]
            },
            "s5" => %{}
          }
        }
      })

    # Run 100 full executions, measuring total time for 400 transitions
    times =
      for _ <- 1..100 do
        {:ok, pid} =
          ExecutionFSM.start_procedure("transition_bench", "1.0", %{}, caller: self())

        start = System.monotonic_time(:microsecond)

        receive do
          {:procedure_complete, _, :completed, _} -> :ok
        after
          5000 -> :timeout
        end

        System.monotonic_time(:microsecond) - start
      end

    # Each execution has 4 transitions
    total_transitions = 100 * 4
    total_us = Enum.sum(times)
    avg_us_per_transition = total_us / total_transitions
    avg_ms_per_transition = avg_us_per_transition / 1000

    target = 5.0
    status = if avg_ms_per_transition < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  #{total_transitions} transitions measured")
    IO.puts("  Average: #{Float.round(avg_ms_per_transition, 3)}ms per transition")
    IO.puts("  Target: < #{target}ms per transition")
    IO.puts("  Status: #{status}")

    %{
      operation: "state_transitions",
      count: total_transitions,
      avg_ms: Float.round(avg_ms_per_transition, 4),
      target_ms: target,
      passed: avg_ms_per_transition < target
    }
  end

  @doc """
  Benchmark full procedure execution (5 states).
  """
  def bench_full_execution do
    IO.puts("\n## Full Procedure Execution (5 states)")
    IO.puts(String.duplicate("-", 40))

    # Use the transition_bench procedure from above
    times =
      for _ <- 1..100 do
        {:ok, _pid} =
          ExecutionFSM.start_procedure("transition_bench", "1.0", %{}, caller: self())

        start = System.monotonic_time(:millisecond)

        receive do
          {:procedure_complete, _, :completed, _} -> :ok
        after
          5000 -> :timeout
        end

        System.monotonic_time(:millisecond) - start
      end

    avg_ms = Enum.sum(times) / 100
    min_ms = Enum.min(times)
    max_ms = Enum.max(times)

    target = 100.0
    status = if avg_ms < target, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  100 full executions")
    IO.puts("  Average: #{Float.round(avg_ms, 2)}ms")
    IO.puts("  Min: #{min_ms}ms, Max: #{max_ms}ms")
    IO.puts("  Target: < #{target}ms per execution")
    IO.puts("  Status: #{status}")

    %{
      operation: "full_execution",
      count: 100,
      avg_ms: Float.round(avg_ms, 2),
      min_ms: min_ms,
      max_ms: max_ms,
      target_ms: target,
      passed: avg_ms < target
    }
  end

  @doc """
  Benchmark concurrent procedure execution.
  """
  def bench_concurrent(count) do
    IO.puts("\n## Concurrent Execution (#{count} parallel)")
    IO.puts(String.duplicate("-", 40))

    # Register a simple procedure for concurrent test
    {:ok, _} =
      Loader.register(%{
        name: "concurrent_bench_#{count}",
        version: "1.0",
        definition: %{
          "initial_state" => "work",
          "states" => %{
            "work" => %{
              "action" => %{
                "module" => "Mimo.ProceduralStore.Steps.SetContext",
                "function" => "execute",
                "args" => [%{"values" => %{"done" => true}}]
              },
              "transitions" => [%{"event" => "success", "target" => "complete"}]
            },
            "complete" => %{}
          }
        }
      })

    {time_us, results} =
      :timer.tc(fn ->
        tasks =
          for i <- 1..count do
            Task.async(fn ->
              {:ok, _pid} =
                ExecutionFSM.start_procedure(
                  "concurrent_bench_#{count}",
                  "1.0",
                  %{"id" => i},
                  caller: self()
                )

              receive do
                {:procedure_complete, _, status, context} -> {status, context}
              after
                10_000 -> {:timeout, %{}}
              end
            end)
          end

        Task.await_many(tasks, 30_000)
      end)

    time_ms = time_us / 1000
    completed = Enum.count(results, fn {status, _} -> status == :completed end)
    timeouts = Enum.count(results, fn {status, _} -> status == :timeout end)

    target_ms = 5000.0
    status = if time_ms < target_ms and completed == count, do: "✅ PASS", else: "❌ FAIL"

    IO.puts("  Total time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Completed: #{completed}/#{count}")
    IO.puts("  Timeouts: #{timeouts}")
    IO.puts("  Target: < #{target_ms}ms, 100% completion")
    IO.puts("  Status: #{status}")

    %{
      operation: "concurrent_#{count}",
      count: count,
      time_ms: Float.round(time_ms, 2),
      completed: completed,
      timeouts: timeouts,
      target_ms: target_ms,
      passed: time_ms < target_ms and completed == count
    }
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
    filename = "bench/results/procedural_store_#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")}.json"

    File.mkdir_p!("bench/results")
    File.write!(filename, Jason.encode!(results, pretty: true))

    IO.puts("Results saved to: #{filename}")
  end
end

# Run the benchmarks
ProceduralStoreBench.run()
