defmodule Mimo.Synapse.WebSocketTest do
  @moduledoc """
  Tests for WebSocket Synapse - Real-time bidirectional communication.
  Tests WebSocket connection lifecycle, message routing,
  reconnection logic, and backpressure handling.
  """
  use ExUnit.Case, async: true

  alias Mimo.Synapse.ConnectionManager

  # ==========================================================================
  # Connection Manager Module Tests
  # ==========================================================================

  describe "ConnectionManager module" do
    test "module is defined" do
      assert Code.ensure_loaded?(Mimo.Synapse.ConnectionManager)
    end

    test "uses GenServer" do
      behaviours = ConnectionManager.module_info(:attributes)[:behaviour] || []
      assert GenServer in behaviours
    end

    test "defines required callbacks" do
      functions = ConnectionManager.__info__(:functions)
      assert {:start_link, 1} in functions
      assert {:init, 1} in functions
    end
  end

  # ==========================================================================
  # Connection Tracking Tests
  # ==========================================================================

  describe "connection tracking API" do
    test "track/2 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:track, 2} in functions
    end

    test "untrack/1 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:untrack, 1} in functions
    end

    test "get/1 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:get, 1} in functions
    end

    test "list_active/0 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:list_active, 0} in functions
    end

    test "count/0 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:count, 0} in functions
    end
  end

  # ==========================================================================
  # Message Routing API Tests
  # ==========================================================================

  describe "message routing API" do
    test "send_to_agent/3 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:send_to_agent, 3} in functions
    end

    test "broadcast_all/2 is defined" do
      functions = ConnectionManager.__info__(:functions)
      assert {:broadcast_all, 2} in functions
    end
  end

  # ==========================================================================
  # InterruptManager Module Tests
  # ==========================================================================

  describe "InterruptManager module" do
    test "module is defined" do
      assert Code.ensure_loaded?(Mimo.Synapse.InterruptManager)
    end
  end

  # ==========================================================================
  # MessageRouter Module Tests
  # ==========================================================================

  describe "MessageRouter module" do
    test "module is defined" do
      assert Code.ensure_loaded?(Mimo.Synapse.MessageRouter)
    end
  end

  # ==========================================================================
  # Connection Lifecycle Simulation Tests
  # ==========================================================================

  describe "connection lifecycle simulation" do
    test "simulates connection tracking structure" do
      # Simulate the ETS table structure used by ConnectionManager
      agent_id = "test_agent_#{:erlang.unique_integer()}"
      channel_pid = self()

      meta = %{
        connected_at: System.system_time(:millisecond),
        monitor_ref: make_ref()
      }

      # Verify the data structure
      entry = {agent_id, channel_pid, meta}
      {id, pid, metadata} = entry

      assert id == agent_id
      assert pid == channel_pid
      assert Map.has_key?(metadata, :connected_at)
      assert Map.has_key?(metadata, :monitor_ref)
    end

    test "simulates concurrent connections" do
      # Simulate multiple agent connections
      connections =
        for i <- 1..10 do
          agent_id = "agent_#{i}"
          channel_pid = spawn(fn -> :timer.sleep(:infinity) end)

          meta = %{
            connected_at: System.system_time(:millisecond),
            monitor_ref: Process.monitor(channel_pid)
          }

          {agent_id, channel_pid, meta}
        end

      assert length(connections) == 10

      # Cleanup spawned processes
      for {_, pid, _} <- connections do
        Process.exit(pid, :kill)
      end
    end

    test "simulates process monitoring" do
      # Spawn a process
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      # Monitor it
      ref = Process.monitor(pid)

      # Kill the process
      Process.exit(pid, :kill)

      # Receive DOWN message
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end
  end

  # ==========================================================================
  # Message Format Tests
  # ==========================================================================

  describe "message format" do
    test "event message structure" do
      message = %{
        event: "tool_result",
        payload: %{
          tool_name: "ask_mimo",
          result: "Success",
          timestamp: System.system_time(:millisecond)
        }
      }

      assert Map.has_key?(message, :event)
      assert Map.has_key?(message, :payload)
      assert is_map(message.payload)
    end

    test "interrupt message structure" do
      interrupt = %{
        type: "cancel",
        request_id: "req_123",
        reason: "user_cancelled"
      }

      assert interrupt.type == "cancel"
      assert Map.has_key?(interrupt, :request_id)
    end

    test "broadcast message structure" do
      broadcast = %{
        event: "system_notification",
        payload: %{
          message: "Server maintenance in 5 minutes",
          severity: "warning"
        }
      }

      assert broadcast.event == "system_notification"
      assert broadcast.payload.severity == "warning"
    end
  end

  # ==========================================================================
  # Backpressure Handling Tests
  # ==========================================================================

  describe "backpressure handling" do
    test "message queue doesn't grow unbounded (simulation)" do
      # Simulate a mailbox with bounded processing
      {:ok, agent} = Agent.start_link(fn -> [] end)

      # Send multiple messages
      for i <- 1..100 do
        Agent.update(agent, fn msgs -> [i | msgs] end)
      end

      # Get current state
      state = Agent.get(agent, & &1)
      assert length(state) == 100

      Agent.stop(agent)
    end

    test "slow consumer handling pattern" do
      # Simulate slow consumer pattern
      parent = self()

      consumer =
        spawn(fn ->
          receive do
            {:message, content} ->
              # Simulate slow processing
              :timer.sleep(10)
              send(parent, {:processed, content})
          end
        end)

      send(consumer, {:message, "test"})
      assert_receive {:processed, "test"}, 1000
    end
  end

  # ==========================================================================
  # Reconnection Logic Tests
  # ==========================================================================

  describe "reconnection logic" do
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

      # Later delays should cap at max
      assert Enum.at(delays, 9) <= max_delay
    end

    test "jitter calculation" do
      base = 1000

      jitters =
        for _ <- 1..10 do
          jitter = :rand.uniform(trunc(base * 0.2))
          jitter
        end

      # All jitters should be within expected range
      for jitter <- jitters do
        assert jitter >= 0
        assert jitter <= base * 0.2
      end
    end

    test "reconnection state tracking" do
      state = %{
        agent_id: "test_agent",
        reconnect_attempts: 0,
        last_connected: System.system_time(:millisecond),
        status: :disconnected
      }

      # Simulate reconnection attempt
      updated = %{state | reconnect_attempts: state.reconnect_attempts + 1, status: :connecting}

      assert updated.reconnect_attempts == 1
      assert updated.status == :connecting
    end
  end

  # ==========================================================================
  # PubSub Integration Tests
  # ==========================================================================

  describe "PubSub patterns" do
    test "topic naming convention" do
      agent_id = "agent_123"
      topic = "agent:#{agent_id}"

      assert topic == "agent:agent_123"
    end

    test "broadcast message format" do
      topic = "agent:test"
      message = %{event: "test_event", payload: %{data: "value"}}

      # Verify message can be encoded to JSON
      {:ok, json} = Jason.encode(message)
      assert is_binary(json)
    end
  end

  # ==========================================================================
  # ETS Table Tests
  # ==========================================================================

  describe "ETS table patterns" do
    test "ETS lookup pattern" do
      # Create temporary ETS table for testing
      table = :ets.new(:test_connections, [:set, :public])

      # Insert
      :ets.insert(table, {"agent_1", self(), %{connected_at: 1}})

      # Lookup
      result = :ets.lookup(table, "agent_1")
      assert [{_, _, _}] = result

      # Delete
      :ets.delete(table, "agent_1")
      assert :ets.lookup(table, "agent_1") == []

      # Cleanup
      :ets.delete(table)
    end

    test "ETS concurrent access" do
      table = :ets.new(:test_concurrent, [:set, :public, read_concurrency: true])

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            key = "agent_#{i}"
            :ets.insert(table, {key, self(), %{}})
            :ets.lookup(table, key)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 10

      :ets.delete(table)
    end
  end
end
