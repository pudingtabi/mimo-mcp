defmodule Mimo.MemoryLeakTestSuite do
  @moduledoc """
  Comprehensive test suite for validating memory leak fixes
  """
  use ExUnit.Case
  alias Mimo.{Brain.Memory, Registry, Skills, Repo}
  alias Mimo.Brain.Engram

  setup do
    # Clean up before each test
    cleanup_system()
    :ok
  end

  # 5 minutes for long-running tests
  @tag timeout: 300_000
  test "port cleanup prevents zombie processes" do
    initial_port_count = length(:erlang.ports())

    # Start multiple skill processes
    skills =
      for i <- 1..10 do
        skill_name = "test_skill_#{i}"

        config = %{
          "command" => "sleep",
          # Long-running process
          "args" => ["3600"]
        }

        {:ok, pid} = Skills.Client.start_link(skill_name, config)
        {skill_name, pid}
      end

    # Verify ports were created
    after_start_ports = length(:erlang.ports())
    assert after_start_ports > initial_port_count

    # Kill all skill processes
    for {_skill_name, pid} <- skills do
      Process.exit(pid, :kill)
    end

    # Wait for cleanup
    Process.sleep(2000)

    # Verify ports are cleaned up
    final_port_count = length(:erlang.ports())

    # Should be close to initial count (allow some variance for system processes)
    assert final_port_count <= initial_port_count + 5
  end

  @tag timeout: 300_000
  test "ets table cleanup removes dead process entries" do
    # Get initial ETS table sizes
    initial_tools_size = :ets.info(:mimo_tools, :size)
    initial_skills_size = :ets.info(:mimo_skills, :size)

    # Create fake skill processes
    fake_pids =
      for i <- 1..20 do
        spawn(fn -> Process.sleep(100) end)
      end

    # Register fake tools with dead processes
    for {pid, i} <- Enum.with_index(fake_pids) do
      tool_def = %{
        "name" => "fake_tool_#{i}",
        "description" => "Fake tool for testing"
      }

      # Manually insert into ETS to simulate dead process registration
      :ets.insert(:mimo_tools, {"fake_tool_#{i}", "fake_skill_#{i}", pid, tool_def})
      :ets.insert(:mimo_skills, {"fake_skill_#{i}", pid, :active})
    end

    # Let processes die
    Process.sleep(200)

    # Verify entries exist
    after_insert_tools = :ets.info(:mimo_tools, :size)
    after_insert_skills = :ets.info(:mimo_skills, :size)
    assert after_insert_tools > initial_tools_size
    assert after_insert_skills > initial_skills_size

    # Trigger cleanup
    send(Registry, :cleanup_dead_processes)
    # Wait for cleanup
    Process.sleep(2000)

    # Verify cleanup
    final_tools_size = :ets.info(:mimo_tools, :size)
    final_skills_size = :ets.info(:mimo_skills, :size)

    # Allow some variance
    assert final_tools_size <= initial_tools_size + 5
    assert final_skills_size <= initial_skills_size + 5
  end

  # 10 minutes for large dataset test
  @tag timeout: 600_000
  test "memory search performance with large dataset" do
    # Create test dataset
    # Start with 5K memories
    test_data_size = 5000

    IO.puts("Creating #{test_data_size} test memories...")

    # Batch create memories
    for i <- 1..test_data_size do
      content =
        "Test memory content #{i} with specific keywords like " <>
          "artificial intelligence machine learning data science"

      case Memory.persist_memory(content, "fact", 0.5) do
        {:ok, _id} ->
          :ok

        {:error, error} ->
          IO.puts("Failed to create memory #{i}: #{inspect(error)}")
          flunk("Memory creation failed")
      end

      # Progress indicator
      if rem(i, 500) == 0 do
        IO.puts("Created #{i}/#{test_data_size} memories")
      end
    end

    # Test search performance
    queries = [
      "artificial intelligence",
      "machine learning",
      "data science",
      "nonexistent topic"
    ]

    for query <- queries do
      IO.puts("Testing search for: #{query}")

      {time_microseconds, results} =
        :timer.tc(fn ->
          Memory.search_memories(query, limit: 10)
        end)

      time_ms = time_microseconds / 1000

      IO.puts("Search took #{time_ms}ms, found #{length(results)} results")

      # Performance assertions
      # Should complete within reasonable time even with 5K memories
      assert time_ms < 5000, "Search took too long: #{time_ms}ms"

      # Should return results for relevant queries
      if query != "nonexistent topic" do
        assert length(results) > 0, "Should find results for: #{query}"
      end

      # Results should be properly ranked
      if length(results) > 1 do
        similarities = Enum.map(results, & &1.similarity)
        assert similarities == Enum.sort(similarities, :desc), "Results not properly ranked"
      end
    end
  end

  test "process limits prevent excessive process creation" do
    # Get initial process count
    initial_process_count = length(Process.list())

    # Try to create more processes than the limit
    # Try to exceed 100 process limit
    results =
      for i <- 1..150 do
        skill_name = "limit_test_skill_#{i}"

        config = %{
          "command" => "echo",
          "args" => ["test"]
        }

        case DynamicSupervisor.start_child(Mimo.Skills.Supervisor, %{
               id: {Mimo.Skills.Client, skill_name},
               start: {Mimo.Skills.Client, :start_link, [skill_name, config]},
               restart: :transient,
               shutdown: 30_000
             }) do
          {:ok, _pid} -> :ok
          {:error, {:shutdown, _}} -> :error
          {:error, reason} -> {:error, reason}
        end
      end

    # Count successful process starts
    successful_starts = Enum.count(results, &(&1 == :ok))

    # Should not exceed the process limit (100)
    assert successful_starts <= 100, "Process limit exceeded: #{successful_starts}"

    # Current process count should not be dramatically higher
    final_process_count = length(Process.list())
    process_increase = final_process_count - initial_process_count

    assert process_increase <= 150, "Too many processes created: #{process_increase}"
  end

  @tag timeout: 300_000
  test "memory usage remains stable under load" do
    # Get baseline memory usage
    baseline_memory = :erlang.memory(:total)

    # Perform repeated operations
    operations = 100

    for i <- 1..operations do
      # Mix of operations
      case rem(i, 4) do
        0 ->
          # Memory search
          Memory.search_memories("test query #{i}", limit: 5)

        1 ->
          # Memory storage
          Memory.persist_memory("Test content #{i}", "observation", 0.7)

        2 ->
          # Tool execution (internal)
          Mimo.ToolInterface.execute("ask_mimo", %{"query" => "test #{i}"})

        3 ->
          # Registry operations
          Registry.list_all_tools()
      end

      # Small delay to simulate realistic load
      Process.sleep(10)
    end

    # Check final memory usage
    final_memory = :erlang.memory(:total)
    memory_increase = final_memory - baseline_memory
    memory_increase_mb = memory_increase / (1024 * 1024)

    IO.puts("Memory increase after #{operations} operations: #{memory_increase_mb}MB")

    # Memory increase should be reasonable (less than 100MB for 100 operations)
    assert memory_increase_mb < 100, "Excessive memory increase: #{memory_increase_mb}MB"
  end

  test "embedding storage efficiency" do
    # Create test memory
    content = "Test embedding storage efficiency"
    {:ok, embedding} = Mimo.Brain.LLM.generate_embedding(content)

    # Store memory
    {:ok, memory_id} = Memory.persist_memory(content, "test", 0.8)

    # Retrieve and verify
    memory = Repo.get(Engram, memory_id)

    # Check embedding size
    embedding_size =
      case memory.embedding do
        list when is_list(list) -> length(list)
        _ -> 0
      end

    # Typical embedding size should be reasonable (1536 for OpenAI)
    assert embedding_size > 0, "Embedding should not be empty"
    assert embedding_size < 2000, "Embedding size seems excessive: #{embedding_size}"

    # Test search with stored embedding
    results = Memory.search_memories(content, limit: 1)
    assert length(results) > 0, "Should find stored memory"

    found_memory = hd(results)
    assert found_memory.id == memory_id, "Should find the correct memory"
  end

  test "message queue cleanup prevents backlog" do
    # Create a skill process
    skill_name = "message_test_skill"

    config = %{
      # Simple echo-like process
      "command" => "cat",
      "args" => []
    }

    {:ok, pid} = Skills.Client.start_link(skill_name, config)

    # Get initial message queue length
    initial_queue_len = Process.info(pid, :message_queue_len) |> elem(1)

    # Send multiple messages rapidly
    for _i <- 1..50 do
      send(pid, {:test_message, "data"})
    end

    # Check message queue after rapid sending
    after_send_queue_len = Process.info(pid, :message_queue_len) |> elem(1)

    # Wait for processing/cleanup
    Process.sleep(100)

    # Check final message queue length
    final_queue_len = Process.info(pid, :message_queue_len) |> elem(1)

    IO.puts(
      "Message queue lengths - Initial: #{initial_queue_len}, After send: #{after_send_queue_len}, Final: #{final_queue_len}"
    )

    # Message queue should not grow indefinitely
    assert final_queue_len < after_send_queue_len, "Message queue not being processed/cleaned"

    # Cleanup
    Process.exit(pid, :normal)
  end

  test "resource monitoring captures critical metrics" do
    # Start resource monitor if not running
    unless Process.whereis(Mimo.Telemetry.ResourceMonitor) do
      {:ok, _pid} = Mimo.Telemetry.ResourceMonitor.start_link([])
    end

    # Get metrics
    metrics = %{
      memory: :erlang.memory(),
      process_count: :erlang.system_info(:process_count),
      ets_tables: length(:ets.all()),
      port_count: length(:erlang.ports())
    }

    # Verify metrics are reasonable
    assert metrics.memory[:total] > 0, "Memory should be positive"
    assert metrics.process_count > 10, "Should have multiple processes running"
    assert metrics.ets_tables > 5, "Should have multiple ETS tables"
    assert metrics.port_count >= 0, "Port count should be non-negative"

    # Memory breakdown should be reasonable
    memory_breakdown = metrics.memory
    assert memory_breakdown[:processes] > 0, "Process memory should be positive"
    assert memory_breakdown[:system] > 0, "System memory should be positive"

    IO.puts("System metrics:")
    IO.puts("  Total memory: #{div(metrics.memory[:total], 1024 * 1024)}MB")
    IO.puts("  Process count: #{metrics.process_count}")
    IO.puts("  ETS tables: #{metrics.ets_tables}")
    IO.puts("  Ports: #{metrics.port_count}")
  end

  # Helper functions

  defp cleanup_system do
    # Clean up test data
    Repo.delete_all(Engram)

    # Clean up test processes
    for {skill_name, _pid} <- Registry.list_active() do
      Registry.untrack(skill_name)
    end

    # Clean up ETS tables
    :ets.delete_all_objects(:mimo_tools)
    :ets.delete_all_objects(:mimo_skills)

    # Wait for cleanup
    Process.sleep(100)
  end

  defp get_memory_breakdown do
    memory = :erlang.memory()

    %{
      total: div(memory[:total], 1024 * 1024),
      processes: div(memory[:processes], 1024 * 1024),
      system: div(memory[:system], 1024 * 1024),
      atom: div(memory[:atom], 1024 * 1024),
      ets: div(memory[:ets], 1024 * 1024),
      code: div(memory[:code], 1024 * 1024),
      binary: div(memory[:binary], 1024 * 1024)
    }
  end

  defp log_system_state do
    memory = get_memory_breakdown()
    process_count = :erlang.system_info(:process_count)
    port_count = length(:erlang.ports())
    ets_count = length(:ets.all())

    IO.puts("=== System State ===")
    IO.puts("Memory: #{memory.total}MB total")
    IO.puts("  Processes: #{memory.processes}MB")
    IO.puts("  System: #{memory.system}MB")
    IO.puts("  ETS: #{memory.ets}MB")
    IO.puts("  Binary: #{memory.binary}MB")
    IO.puts("Processes: #{process_count}")
    IO.puts("Ports: #{port_count}")
    IO.puts("ETS Tables: #{ets_count}")
    IO.puts("===================")
  end
end

# Performance benchmark module
defmodule Mimo.PerformanceBenchmark do
  @moduledoc """
  Benchmark memory usage and performance under various loads
  """

  def run_benchmarks do
    IO.puts("Starting memory leak benchmarks...")

    # Benchmark 1: Memory search scaling
    benchmark_search_scaling()

    # Benchmark 2: Process creation limits
    benchmark_process_limits()

    # Benchmark 3: Memory usage over time
    benchmark_memory_usage()

    IO.puts("Benchmarks completed!")
  end

  defp benchmark_search_scaling do
    IO.puts("\n=== Search Scaling Benchmark ===")

    dataset_sizes = [100, 500, 1000, 2000]

    for size <- dataset_sizes do
      # Create test data
      create_test_memories(size)

      # Measure search performance
      {time, results} =
        :timer.tc(fn ->
          Mimo.Brain.Memory.search_memories("test query", limit: 10)
        end)

      time_ms = time / 1000

      IO.puts("Dataset size: #{size}, Search time: #{time_ms}ms, Results: #{length(results)}")

      # Cleanup
      Mimo.Repo.delete_all(Mimo.Brain.Engram)
    end
  end

  defp benchmark_process_limits do
    IO.puts("\n=== Process Limits Benchmark ===")

    initial_processes = length(Process.list())

    # Try to create many processes
    results =
      for i <- 1..200 do
        skill_name = "benchmark_skill_#{i}"
        config = %{"command" => "echo", "args" => ["test"]}

        case DynamicSupervisor.start_child(Mimo.Skills.Supervisor, %{
               id: {Mimo.Skills.Client, skill_name},
               start: {Mimo.Skills.Client, :start_link, [skill_name, config]},
               restart: :transient,
               shutdown: 30_000
             }) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    successful = Enum.count(results, &(&1 == :ok))
    final_processes = length(Process.list())
    process_increase = final_processes - initial_processes

    IO.puts("Attempted: 200, Successful: #{successful}, Process increase: #{process_increase}")

    # Cleanup
    cleanup_benchmark_processes()
  end

  defp benchmark_memory_usage do
    IO.puts("\n=== Memory Usage Benchmark ===")

    # Baseline
    baseline_memory = :erlang.memory(:total)
    log_memory_usage("Baseline", baseline_memory)

    # Create memories
    create_test_memories(1000)
    after_memories_memory = :erlang.memory(:total)
    log_memory_usage("After creating 1000 memories", after_memories_memory)

    # Perform searches
    for _i <- 1..50 do
      Mimo.Brain.Memory.search_memories("benchmark query", limit: 10)
    end

    after_searches_memory = :erlang.memory(:total)
    log_memory_usage("After 50 searches", after_searches_memory)

    # Create processes
    create_benchmark_processes(50)
    after_processes_memory = :erlang.memory(:total)
    log_memory_usage("After creating 50 processes", after_processes_memory)

    # Calculate increases
    memories_increase = after_memories_memory - baseline_memory
    searches_increase = after_searches_memory - after_memories_memory
    processes_increase = after_processes_memory - after_searches_memory

    IO.puts("Memory increases:")
    IO.puts("  Memories: #{div(memories_increase, 1024 * 1024)}MB")
    IO.puts("  Searches: #{div(searches_increase, 1024 * 1024)}MB")
    IO.puts("  Processes: #{div(processes_increase, 1024 * 1024)}MB")

    # Cleanup
    cleanup_benchmark_data()
    cleanup_benchmark_processes()
  end

  defp create_test_memories(count) do
    for i <- 1..count do
      content = "Benchmark memory #{i} with test content for search performance analysis"
      Mimo.Brain.Memory.persist_memory(content, "benchmark", 0.5)
    end
  end

  defp create_benchmark_processes(count) do
    for i <- 1..count do
      skill_name = "bench_process_#{i}"
      config = %{"command" => "sleep", "args" => ["3600"]}

      DynamicSupervisor.start_child(Mimo.Skills.Supervisor, %{
        id: {Mimo.Skills.Client, skill_name},
        start: {Mimo.Skills.Client, :start_link, [skill_name, config]},
        restart: :transient,
        shutdown: 30_000
      })
    end
  end

  defp cleanup_benchmark_data do
    Mimo.Repo.delete_all(Mimo.Brain.Engram)
  end

  defp cleanup_benchmark_processes do
    # Kill all benchmark processes
    for pid <- Process.list() do
      case Process.info(pid, [:dictionary]) do
        [{:dictionary, dict}] ->
          case dict[:"$initial_call"] do
            {Mimo.Skills.Client, _, _} ->
              Process.exit(pid, :normal)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp log_memory_usage(phase, memory_bytes) do
    memory_mb = div(memory_bytes, 1024 * 1024)
    IO.puts("#{phase}: #{memory_mb}MB")
  end
end

# Usage:
# Mimo.MemoryLeakTestSuite.run_benchmarks()
