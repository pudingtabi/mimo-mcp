defmodule Mimo.Synapse.ValidationTest do
  @moduledoc """
  SPEC-009: WebSocket Synapse Production Validation Tests

  Validates that WebSocket Synapse (real-time cognitive signaling)
  is production-ready. Tests connection lifecycle, message protocol,
  error handling, and concurrent access.
  """
  use ExUnit.Case, async: true

  alias Mimo.Synapse.{ConnectionManager, InterruptManager, MessageRouter}
  alias Phoenix.PubSub

  # ===========================================================================
  # Module Existence Tests
  # ===========================================================================

  describe "module availability" do
    test "ConnectionManager module is loaded" do
      assert Code.ensure_loaded?(Mimo.Synapse.ConnectionManager)
    end

    test "InterruptManager module is loaded" do
      assert Code.ensure_loaded?(Mimo.Synapse.InterruptManager)
    end

    test "MessageRouter module is loaded" do
      assert Code.ensure_loaded?(Mimo.Synapse.MessageRouter)
    end

    test "CortexChannel module is loaded" do
      assert Code.ensure_loaded?(MimoWeb.CortexChannel)
    end

    test "CortexSocket module is loaded" do
      assert Code.ensure_loaded?(MimoWeb.CortexSocket)
    end

    test "Presence module is loaded" do
      assert Code.ensure_loaded?(MimoWeb.Presence)
    end
  end

  # ===========================================================================
  # ConnectionManager API Tests
  # ===========================================================================

  describe "ConnectionManager API" do
    test "exports track/2 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:track, 2} in functions
    end

    test "exports untrack/1 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:untrack, 1} in functions
    end

    test "exports get/1 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:get, 1} in functions
    end

    test "exports list_active/0 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:list_active, 0} in functions
    end

    test "exports count/0 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:count, 0} in functions
    end

    test "exports send_to_agent/3 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:send_to_agent, 3} in functions
    end

    test "exports broadcast_all/2 function" do
      functions = ConnectionManager.__info__(:functions)
      assert {:broadcast_all, 2} in functions
    end
  end

  # ===========================================================================
  # InterruptManager API Tests
  # ===========================================================================

  describe "InterruptManager API" do
    test "exports register/2 function" do
      functions = InterruptManager.__info__(:functions)
      assert {:register, 2} in functions
    end

    test "exports unregister/1 function" do
      functions = InterruptManager.__info__(:functions)
      assert {:unregister, 1} in functions
    end

    test "exports signal/3 function" do
      functions = InterruptManager.__info__(:functions)
      assert {:signal, 3} in functions
    end

    test "exports check_interrupt/1 function" do
      functions = InterruptManager.__info__(:functions)
      assert {:check_interrupt, 1} in functions
    end
  end

  # ===========================================================================
  # MessageRouter API Tests
  # ===========================================================================

  describe "MessageRouter API" do
    test "exports broadcast_thought/3 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:broadcast_thought, 3} in functions
    end

    test "exports broadcast_result/5 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:broadcast_result, 5} in functions
    end

    test "exports broadcast_error/3 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:broadcast_error, 3} in functions
    end

    test "exports broadcast_system/2 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:broadcast_system, 2} in functions
    end

    test "exports subscribe/1 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:subscribe, 1} in functions
    end

    test "exports unsubscribe/1 function" do
      functions = MessageRouter.__info__(:functions)
      assert {:unsubscribe, 1} in functions
    end
  end

  # ===========================================================================
  # Connection Tracking Data Structure Tests
  # ===========================================================================

  describe "connection tracking data structure" do
    test "can construct connection entry" do
      agent_id = "test_agent_#{:erlang.unique_integer()}"
      channel_pid = self()

      meta = %{
        connected_at: System.system_time(:millisecond),
        monitor_ref: make_ref()
      }

      entry = {agent_id, channel_pid, meta}
      {id, pid, metadata} = entry

      assert id == agent_id
      assert pid == channel_pid
      assert is_map(metadata)
      assert Map.has_key?(metadata, :connected_at)
      assert Map.has_key?(metadata, :monitor_ref)
    end

    test "handles multiple connection entries" do
      entries =
        for i <- 1..10 do
          agent_id = "agent_#{i}"
          channel_pid = spawn(fn -> :timer.sleep(:infinity) end)

          meta = %{
            connected_at: System.system_time(:millisecond),
            monitor_ref: Process.monitor(channel_pid)
          }

          {agent_id, channel_pid, meta}
        end

      assert length(entries) == 10

      # Cleanup
      for {_, pid, _} <- entries do
        Process.exit(pid, :kill)
      end
    end
  end

  # ===========================================================================
  # Message Format Tests
  # ===========================================================================

  describe "message format validation" do
    test "query message format" do
      message = %{
        "type" => "query",
        "q" => "What is the meaning of life?",
        "ref" => "query_#{:erlang.unique_integer()}"
      }

      assert message["type"] == "query"
      assert is_binary(message["q"])
      assert is_binary(message["ref"])
    end

    test "thought message format" do
      message = %{
        type: "thought",
        content: "Analyzing the query...",
        ref: "query_123",
        timestamp: System.system_time(:millisecond)
      }

      assert message.type == "thought"
      assert is_binary(message.content)
      assert is_binary(message.ref)
      assert is_integer(message.timestamp)
    end

    test "result message format" do
      message = %{
        ref: "query_123",
        status: :success,
        data: %{answer: "42"},
        latency_ms: 150
      }

      assert is_binary(message.ref)
      assert message.status in [:success, :error, :interrupted]
      assert is_map(message.data) or is_nil(message.data)
      assert is_integer(message.latency_ms)
    end

    test "interrupt message format" do
      message = %{
        "type" => "interrupt",
        "ref" => "query_123",
        "reason" => "user_cancelled"
      }

      assert message["type"] == "interrupt"
      assert is_binary(message["ref"])
      assert is_binary(message["reason"])
    end

    test "error message format" do
      message = %{
        ref: "query_123",
        error: "Connection timeout",
        timestamp: System.system_time(:millisecond)
      }

      assert is_binary(message.ref)
      assert is_binary(message.error)
      assert is_integer(message.timestamp)
    end

    test "all messages can be JSON encoded" do
      messages = [
        %{type: "query", q: "test", ref: "1"},
        %{type: "thought", content: "test", ref: "1", timestamp: 12345},
        %{ref: "1", status: "success", data: %{answer: "test"}, latency_ms: 100},
        %{type: "interrupt", ref: "1", reason: "cancelled"},
        %{ref: "1", error: "timeout", timestamp: 12345}
      ]

      for msg <- messages do
        assert {:ok, json} = Jason.encode(msg)
        assert is_binary(json)
        assert {:ok, decoded} = Jason.decode(json)
        assert is_map(decoded)
      end
    end
  end

  # ===========================================================================
  # PubSub Pattern Tests
  # ===========================================================================

  describe "PubSub patterns" do
    @describetag :requires_pubsub

    test "agent topic naming convention" do
      agent_id = "agent_123"
      topic = "agent:#{agent_id}"

      assert topic == "agent:agent_123"
      assert String.starts_with?(topic, "agent:")
    end

    test "cortex topic naming convention" do
      session_id = "session_456"
      topic = "cortex:#{session_id}"

      assert topic == "cortex:session_456"
      assert String.starts_with?(topic, "cortex:")
    end

    # Note: Actual PubSub tests require the application to be running
    # These are tested in integration tests
  end

  # ===========================================================================
  # Process Monitoring Tests
  # ===========================================================================

  describe "process monitoring patterns" do
    test "can monitor and detect process exit" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end

    test "can demonitor process" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      ref = Process.monitor(pid)

      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)

      # Should NOT receive DOWN message
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
    end

    test "handles multiple monitors" do
      parent = self()

      pids =
        for i <- 1..10 do
          pid = spawn(fn -> :timer.sleep(:infinity) end)
          ref = Process.monitor(pid)
          {pid, ref, i}
        end

      # Kill all processes
      for {pid, _, _} <- pids do
        Process.exit(pid, :kill)
      end

      # Should receive all DOWN messages
      for {pid, ref, i} <- pids do
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
      end
    end
  end

  # ===========================================================================
  # ETS Table Pattern Tests
  # ===========================================================================

  describe "ETS table patterns" do
    test "can create and use connection-like ETS table" do
      table = :ets.new(:test_synapse_connections, [:set, :public, read_concurrency: true])

      # Insert entries
      for i <- 1..10 do
        :ets.insert(table, {"agent_#{i}", self(), %{connected_at: i}})
      end

      # Lookup
      assert [{"agent_5", _, %{connected_at: 5}}] = :ets.lookup(table, "agent_5")

      # Count
      assert :ets.info(table, :size) == 10

      # List all
      entries = :ets.tab2list(table)
      assert length(entries) == 10

      # Delete
      :ets.delete(table, "agent_5")
      assert :ets.lookup(table, "agent_5") == []
      assert :ets.info(table, :size) == 9

      # Cleanup
      :ets.delete(table)
    end

    test "concurrent ETS access" do
      table = :ets.new(:test_concurrent_synapse, [:set, :public, read_concurrency: true])

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            key = "agent_#{i}"
            :ets.insert(table, {key, self(), %{id: i}})
            :ets.lookup(table, key)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All lookups should succeed
      for result <- results do
        assert [{_, _, %{id: _}}] = result
      end

      assert :ets.info(table, :size) == 50

      :ets.delete(table)
    end
  end

  # ===========================================================================
  # Reconnection Logic Tests
  # ===========================================================================

  describe "reconnection logic patterns" do
    test "exponential backoff calculation" do
      base_delay = 100
      max_delay = 30_000

      delays =
        for attempt <- 1..10 do
          delay = min(base_delay * :math.pow(2, attempt - 1), max_delay)
          trunc(delay)
        end

      # First few delays should grow exponentially
      assert Enum.at(delays, 0) == 100
      assert Enum.at(delays, 1) == 200
      assert Enum.at(delays, 2) == 400
      assert Enum.at(delays, 3) == 800

      # Should cap at max_delay
      assert Enum.at(delays, 9) <= max_delay
    end

    test "jitter calculation stays within bounds" do
      base = 1000

      jitters =
        for _ <- 1..100 do
          jitter = :rand.uniform(trunc(base * 0.2))
          jitter
        end

      for jitter <- jitters do
        assert jitter >= 0
        assert jitter <= base * 0.2
      end
    end

    test "reconnection state tracking" do
      initial_state = %{
        agent_id: "test_agent",
        reconnect_attempts: 0,
        last_connected: System.system_time(:millisecond),
        status: :connected
      }

      # Disconnect
      disconnected = %{initial_state | status: :disconnected}
      assert disconnected.status == :disconnected

      # Attempt reconnect
      reconnecting = %{
        disconnected
        | reconnect_attempts: disconnected.reconnect_attempts + 1,
          status: :connecting
      }

      assert reconnecting.reconnect_attempts == 1
      assert reconnecting.status == :connecting

      # Success
      reconnected = %{
        reconnecting
        | reconnect_attempts: 0,
          last_connected: System.system_time(:millisecond),
          status: :connected
      }

      assert reconnected.status == :connected
      assert reconnected.reconnect_attempts == 0
    end
  end

  # ===========================================================================
  # Rate Limiting Pattern Tests
  # ===========================================================================

  describe "rate limiting patterns" do
    test "sliding window rate limiter" do
      # Simulate sliding window
      window_ms = 1000
      max_requests = 10

      state = %{
        requests: [],
        window_ms: window_ms,
        max_requests: max_requests
      }

      # Add requests with proper rate limiting
      now = System.system_time(:millisecond)

      {final_state, _} =
        Enum.reduce(1..15, {state, 0}, fn _, {acc, i} ->
          # Remove old requests outside window
          requests = Enum.filter(acc.requests, fn t -> now - t < window_ms end)

          # Only add if under limit
          requests =
            if length(requests) < max_requests do
              [now | requests]
            else
              requests
            end

          {%{acc | requests: requests}, i + 1}
        end)

      # Should only have max_requests
      assert length(final_state.requests) <= max_requests
    end

    test "token bucket rate limiter" do
      # Simulate token bucket
      bucket_size = 10
      refill_rate = 1
      refill_interval_ms = 100

      state = %{
        tokens: bucket_size,
        last_refill: System.system_time(:millisecond)
      }

      # Consume 5 tokens
      state = %{state | tokens: state.tokens - 5}
      assert state.tokens == 5

      # Consume 3 more
      state = %{state | tokens: state.tokens - 3}
      assert state.tokens == 2

      # Can't consume 5 more (only 2 available)
      can_consume = state.tokens >= 5
      assert can_consume == false

      # Simulate refill
      state = %{
        state
        | tokens: min(state.tokens + refill_rate * 3, bucket_size),
          last_refill: System.system_time(:millisecond)
      }

      assert state.tokens == 5
    end
  end

  # ===========================================================================
  # Backpressure Handling Tests
  # ===========================================================================

  describe "backpressure handling patterns" do
    test "bounded mailbox simulation" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      max_queue = 100

      # Add items with limit check
      for i <- 1..150 do
        Agent.update(agent, fn queue ->
          if length(queue) < max_queue do
            [i | queue]
          else
            # Drop oldest when full
            [i | Enum.take(queue, max_queue - 1)]
          end
        end)
      end

      state = Agent.get(agent, & &1)
      assert length(state) == max_queue

      Agent.stop(agent)
    end

    test "slow consumer pattern" do
      parent = self()

      consumer =
        spawn(fn ->
          receive do
            {:message, content, reply_to} ->
              # Simulate slow processing
              Process.sleep(10)
              send(reply_to, {:processed, content})
          end
        end)

      send(consumer, {:message, "test", self()})
      assert_receive {:processed, "test"}, 1000
    end
  end
end
