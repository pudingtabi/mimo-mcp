defmodule WebSocketLoadTest do
  @moduledoc """
  SPEC-009: WebSocket Synapse Load Testing

  Load tests for validating WebSocket Synapse performance targets:
  - Connection throughput
  - Message latency
  - Concurrent connections
  - Memory usage per connection

  Run with: mix run bench/websocket_load_test.exs
  """

  alias Mimo.Synapse.{ConnectionManager, MessageRouter}
  alias Phoenix.PubSub

  @pubsub Mimo.PubSub
  @connection_targets [10, 50, 100]
  @message_counts [100, 500, 1000]

  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("    SPEC-009: WebSocket Synapse Load Test")
    IO.puts(String.duplicate("=", 70))
    IO.puts("Date: #{DateTime.utc_now() |> DateTime.to_string()}")
    IO.puts(String.duplicate("=", 70) <> "\n")

    results = %{
      pubsub: test_pubsub_throughput(),
      connection_simulation: test_connection_simulation(),
      message_routing: test_message_routing(),
      concurrent_pubsub: test_concurrent_pubsub(),
      memory: test_memory_usage()
    }

    generate_summary(results)
    results
  end

  # ===========================================================================
  # PubSub Throughput Test
  # ===========================================================================

  defp test_pubsub_throughput do
    IO.puts("## PubSub Throughput Test")
    IO.puts(String.duplicate("-", 50))

    results =
      for count <- @message_counts do
        topic = "load_test:#{:erlang.unique_integer()}"
        parent = self()

        # Subscribe
        :ok = PubSub.subscribe(@pubsub, topic)

        # Start receiver process
        receiver =
          spawn(fn ->
            received = receive_messages(count, [])
            send(parent, {:received, length(received)})
          end)

        # Give receiver time to start
        Process.sleep(10)

        # Send messages and measure time
        {time_us, _} =
          :timer.tc(fn ->
            for i <- 1..count do
              :ok = PubSub.broadcast(@pubsub, topic, {:msg, i})
            end
          end)

        time_ms = time_us / 1000
        rate = count / (time_us / 1_000_000)

        # Wait for receiver
        receive do
          {:received, recv_count} ->
            IO.puts("\n  #{count} messages:")
            IO.puts("    Send time: #{Float.round(time_ms, 2)}ms")
            IO.puts("    Send rate: #{Float.round(rate, 0)} msg/sec")
            IO.puts("    Received: #{recv_count}/#{count}")
            IO.puts("    Target: > 1000 msg/sec | Status: #{status(rate >= 1000)}")

            %{
              count: count,
              time_ms: time_ms,
              rate: rate,
              received: recv_count,
              pass: rate >= 1000
            }
        after
          5000 ->
            IO.puts("\n  #{count} messages: TIMEOUT")
            %{count: count, time_ms: 0, rate: 0, received: 0, pass: false}
        end
      end

    # Cleanup
    PubSub.unsubscribe(@pubsub, "load_test:*")
    IO.puts("\n")
    results
  end

  defp receive_messages(0, acc), do: acc

  defp receive_messages(remaining, acc) do
    receive do
      {:msg, n} -> receive_messages(remaining - 1, [n | acc])
    after
      100 -> acc
    end
  end

  # ===========================================================================
  # Connection Simulation Test
  # ===========================================================================

  defp test_connection_simulation do
    IO.puts("## Connection Simulation Test")
    IO.puts(String.duplicate("-", 50))

    results =
      for target <- @connection_targets do
        parent = self()

        # Create simulated connections (processes with PubSub subscriptions)
        {time_us, connections} =
          :timer.tc(fn ->
            for i <- 1..target do
              topic = "agent:sim_#{i}"

              pid =
                spawn(fn ->
                  :ok = PubSub.subscribe(@pubsub, topic)

                  receive do
                    :stop -> :ok
                  end
                end)

              {pid, topic}
            end
          end)

        time_ms = time_us / 1000
        rate = target / (time_us / 1_000_000)

        IO.puts("\n  #{target} simulated connections:")
        IO.puts("    Setup time: #{Float.round(time_ms, 2)}ms")
        IO.puts("    Rate: #{Float.round(rate, 0)} conn/sec")
        IO.puts("    Target: > 100 conn/sec | Status: #{status(rate >= 100)}")

        # Cleanup connections
        for {pid, _topic} <- connections do
          send(pid, :stop)
        end

        %{
          count: target,
          time_ms: time_ms,
          rate: rate,
          pass: rate >= 100
        }
      end

    IO.puts("\n")
    results
  end

  # ===========================================================================
  # Message Routing Test
  # ===========================================================================

  defp test_message_routing do
    IO.puts("## Message Routing Latency Test")
    IO.puts(String.duplicate("-", 50))

    # Test message routing latency
    agent_id = "latency_test_#{:erlang.unique_integer()}"
    topic = "agent:#{agent_id}"

    :ok = PubSub.subscribe(@pubsub, topic)

    # Warm up
    for _ <- 1..10 do
      MessageRouter.broadcast_thought(agent_id, "warmup", %{type: "test"})
      receive do
        _ -> :ok
      after
        100 -> :ok
      end
    end

    # Measure latency for 100 messages
    latencies =
      for _ <- 1..100 do
        start = System.monotonic_time(:microsecond)
        MessageRouter.broadcast_thought(agent_id, "lat_ref", %{type: "latency_test"})

        receive do
          _ ->
            stop = System.monotonic_time(:microsecond)
            stop - start
        after
          1000 -> 1_000_000
        end
      end

    avg_latency = Enum.sum(latencies) / length(latencies)
    min_latency = Enum.min(latencies)
    max_latency = Enum.max(latencies)
    p95_latency = Enum.at(Enum.sort(latencies), 94)
    p99_latency = Enum.at(Enum.sort(latencies), 98)

    IO.puts("\n  100 message round-trips:")
    IO.puts("    Avg latency: #{Float.round(avg_latency, 2)}μs")
    IO.puts("    Min latency: #{min_latency}μs")
    IO.puts("    Max latency: #{max_latency}μs")
    IO.puts("    P95 latency: #{p95_latency}μs")
    IO.puts("    P99 latency: #{p99_latency}μs")
    IO.puts("    Target: < 10ms avg | Status: #{status(avg_latency < 10_000)}")

    PubSub.unsubscribe(@pubsub, topic)
    IO.puts("\n")

    %{
      avg_us: avg_latency,
      min_us: min_latency,
      max_us: max_latency,
      p95_us: p95_latency,
      p99_us: p99_latency,
      pass: avg_latency < 10_000
    }
  end

  # ===========================================================================
  # Concurrent PubSub Test
  # ===========================================================================

  defp test_concurrent_pubsub do
    IO.puts("## Concurrent PubSub Test")
    IO.puts(String.duplicate("-", 50))

    # Test many publishers/subscribers simultaneously
    parent = self()
    num_pairs = 50
    messages_per_pair = 20

    {time_us, _} =
      :timer.tc(fn ->
        tasks =
          for i <- 1..num_pairs do
            Task.async(fn ->
              topic = "concurrent:#{i}"

              # Subscribe
              :ok = PubSub.subscribe(@pubsub, topic)

              # Send messages
              for j <- 1..messages_per_pair do
                :ok = PubSub.broadcast(@pubsub, topic, {:msg, i, j})
              end

              # Receive messages
              received =
                for _ <- 1..messages_per_pair do
                  receive do
                    {:msg, ^i, j} -> j
                  after
                    100 -> nil
                  end
                end

              PubSub.unsubscribe(@pubsub, topic)
              Enum.count(received, & &1)
            end)
          end

        Task.await_many(tasks, 30_000)
      end)

    time_ms = time_us / 1000
    total_messages = num_pairs * messages_per_pair
    rate = total_messages / (time_us / 1_000_000)

    IO.puts("\n  #{num_pairs} concurrent pub/sub pairs, #{messages_per_pair} msgs each:")
    IO.puts("    Total messages: #{total_messages}")
    IO.puts("    Total time: #{Float.round(time_ms, 2)}ms")
    IO.puts("    Rate: #{Float.round(rate, 0)} msg/sec")
    IO.puts("    Target: > 500 msg/sec | Status: #{status(rate >= 500)}")

    IO.puts("\n")

    %{
      pairs: num_pairs,
      messages_per_pair: messages_per_pair,
      total: total_messages,
      time_ms: time_ms,
      rate: rate,
      pass: rate >= 500
    }
  end

  # ===========================================================================
  # Memory Usage Test
  # ===========================================================================

  defp test_memory_usage do
    IO.puts("## Memory Usage Test")
    IO.puts(String.duplicate("-", 50))

    # Force garbage collection
    :erlang.garbage_collect()
    Process.sleep(100)
    before_memory = :erlang.memory(:total)

    # Create 100 simulated connections
    connections =
      for i <- 1..100 do
        topic = "mem_test:#{i}"

        pid =
          spawn(fn ->
            :ok = PubSub.subscribe(@pubsub, topic)

            # Store some state
            state = %{
              agent_id: "agent_#{i}",
              connected_at: System.system_time(:millisecond),
              subscribed_events: ["thought", "result"],
              buffer: []
            }

            loop(state, topic)
          end)

        {pid, topic}
      end

    # Wait for processes to stabilize
    Process.sleep(200)

    # Measure memory after connections
    :erlang.garbage_collect()
    after_memory = :erlang.memory(:total)

    memory_increase = after_memory - before_memory
    per_connection = memory_increase / 100

    IO.puts("\n  100 simulated connections:")
    IO.puts("    Memory before: #{Float.round(before_memory / 1_000_000, 2)}MB")
    IO.puts("    Memory after: #{Float.round(after_memory / 1_000_000, 2)}MB")
    IO.puts("    Increase: #{Float.round(memory_increase / 1_000_000, 2)}MB")
    IO.puts("    Per connection: #{Float.round(per_connection / 1024, 2)}KB")
    IO.puts("    Target: < 1MB per conn | Status: #{status(per_connection < 1_000_000)}")

    # Cleanup
    for {pid, _topic} <- connections do
      send(pid, :stop)
    end

    IO.puts("\n")

    %{
      connections: 100,
      memory_increase_bytes: memory_increase,
      per_connection_bytes: per_connection,
      pass: per_connection < 1_000_000
    }
  end

  defp loop(state, topic) do
    receive do
      :stop ->
        PubSub.unsubscribe(@pubsub, topic)
        :ok

      msg ->
        new_state = %{state | buffer: [msg | Enum.take(state.buffer, 99)]}
        loop(new_state, topic)
    end
  end

  # ===========================================================================
  # Summary Generation
  # ===========================================================================

  defp generate_summary(results) do
    IO.puts(String.duplicate("=", 70))
    IO.puts("                        SUMMARY")
    IO.puts(String.duplicate("=", 70))

    pubsub_pass = Enum.count(results.pubsub, & &1.pass)
    conn_pass = Enum.count(results.connection_simulation, & &1.pass)
    routing_pass = if results.message_routing.pass, do: 1, else: 0
    concurrent_pass = if results.concurrent_pubsub.pass, do: 1, else: 0
    memory_pass = if results.memory.pass, do: 1, else: 0

    total_tests = length(@message_counts) + length(@connection_targets) + 3
    total_pass = pubsub_pass + conn_pass + routing_pass + concurrent_pass + memory_pass

    IO.puts("\n  Test Results:")
    IO.puts("    PubSub Throughput: #{pubsub_pass}/#{length(@message_counts)} passing")
    IO.puts("    Connection Simulation: #{conn_pass}/#{length(@connection_targets)} passing")
    IO.puts("    Message Routing: #{routing_pass}/1 passing")
    IO.puts("    Concurrent PubSub: #{concurrent_pass}/1 passing")
    IO.puts("    Memory Usage: #{memory_pass}/1 passing")
    IO.puts("")
    IO.puts("  Overall: #{total_pass}/#{total_tests} tests passing")

    # Calculate key metrics
    avg_throughput =
      results.pubsub
      |> Enum.map(& &1.rate)
      |> Enum.sum()
      |> Kernel./(length(results.pubsub))

    avg_latency_ms = results.message_routing.avg_us / 1000
    memory_per_conn_kb = results.memory.per_connection_bytes / 1024

    IO.puts("\n  Key Metrics:")
    IO.puts("    Avg PubSub Throughput: #{Float.round(avg_throughput, 0)} msg/sec")
    IO.puts("    Avg Message Latency: #{Float.round(avg_latency_ms, 3)}ms")
    IO.puts("    Memory per Connection: #{Float.round(memory_per_conn_kb, 2)}KB")

    overall_status =
      if total_pass == total_tests do
        "✅ PRODUCTION READY"
      else
        if total_pass >= total_tests * 0.7 do
          "⚠️ MOSTLY READY (some targets missed)"
        else
          "❌ NOT READY"
        end
      end

    IO.puts("\n  Status: #{overall_status}")
    IO.puts(String.duplicate("=", 70) <> "\n")
  end

  defp status(true), do: "✅ PASS"
  defp status(false), do: "❌ FAIL"
end

# Run the load test
WebSocketLoadTest.run()
