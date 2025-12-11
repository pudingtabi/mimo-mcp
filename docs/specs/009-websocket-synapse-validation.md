# SPEC-009: WebSocket Synapse Production Validation

## Overview

**Goal**: Prove WebSocket Synapse (real-time cognitive signaling) is production-ready.

**Current Status**: ⚠️ Beta  
**Target Status**: ✅ Production Ready

## Production Readiness Criteria

### 1. Functional Completeness

| Feature | Required | Current | Test Coverage |
|---------|----------|---------|---------------|
| Channel connection | ✅ | ✅ | Needs validation |
| Authentication | ✅ | ✅ | Needs validation |
| Query streaming | ✅ | ✅ | Needs validation |
| Thought broadcast | ✅ | ✅ | Needs validation |
| Interruption | ✅ | Partial | Needs implementation |
| Reconnection | ✅ | Partial | Needs testing |
| Presence tracking | ⚠️ | ❌ | Optional v1 |

### 2. Performance Benchmarks

| Metric | Target | Test Method |
|--------|--------|-------------|
| Connection time | < 100ms | Measure handshake |
| Message latency | < 10ms | Round-trip ping |
| Concurrent connections | 100+ | Load test |
| Messages/sec | 1000+ | Throughput test |
| Memory per connection | < 1MB | Profile |

### 3. Reliability Tests

| Scenario | Test |
|----------|------|
| Client disconnect | Server cleans up properly |
| Server restart | Clients reconnect |
| Network interruption | Graceful reconnection |
| Invalid messages | Rejected without crash |
| Authentication failure | Connection rejected |

---

## Test Implementation

### Task 1: Channel Connection Tests

**File**: `test/mimo/synapse/channel_test.exs`

```elixir
defmodule Mimo.Synapse.ChannelTest do
  use MimoWeb.ChannelCase
  
  alias MimoWeb.CortexChannel

  @valid_token "test_api_key"

  describe "join/3" do
    test "joins channel with valid token" do
      {:ok, _, socket} =
        socket(MimoWeb.UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{"api_key" => @valid_token})
      
      assert socket.assigns.authenticated == true
    end

    test "rejects join with invalid token" do
      result =
        socket(MimoWeb.UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{"api_key" => "invalid"})
      
      assert {:error, %{reason: "unauthorized"}} = result
    end

    test "rejects join without token" do
      result =
        socket(MimoWeb.UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{})
      
      assert {:error, %{reason: "unauthorized"}} = result
    end
  end

  describe "handle_in query" do
    setup do
      {:ok, _, socket} =
        socket(MimoWeb.UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{"api_key" => @valid_token})
      
      {:ok, socket: socket}
    end

    test "processes query and sends result", %{socket: socket} do
      ref = push(socket, "query", %{"q" => "What is 2+2?", "ref" => "q1"})
      
      # Should receive thoughts and result
      assert_push "thought", %{type: _, content: _}, 5000
      assert_push "result", %{ref: "q1", status: "success"}, 5000
    end

    test "handles invalid query format", %{socket: socket} do
      ref = push(socket, "query", %{"invalid" => "data"})
      
      assert_push "error", %{reason: _}, 1000
    end
  end

  describe "handle_in interrupt" do
    setup do
      {:ok, _, socket} =
        socket(MimoWeb.UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{"api_key" => @valid_token})
      
      {:ok, socket: socket}
    end

    test "interrupts ongoing query", %{socket: socket} do
      # Start long query
      push(socket, "query", %{"q" => "Long running query...", "ref" => "q1"})
      
      # Interrupt
      push(socket, "interrupt", %{"ref" => "q1", "reason" => "user_cancelled"})
      
      # Should receive interrupted status
      assert_push "result", %{ref: "q1", status: "interrupted"}, 5000
    end
  end
end
```

### Task 2: WebSocket Handler Tests

**File**: `test/mimo/synapse/websocket_handler_test.exs`

```elixir
defmodule Mimo.Synapse.WebSocketHandlerTest do
  use ExUnit.Case, async: true
  
  alias Mimo.Synapse.WebSocketHandler

  describe "message parsing" do
    test "parses valid query message" do
      msg = %{"type" => "query", "q" => "test", "ref" => "1"}
      
      assert {:query, %{q: "test", ref: "1"}} = WebSocketHandler.parse_message(msg)
    end

    test "parses valid interrupt message" do
      msg = %{"type" => "interrupt", "ref" => "1", "reason" => "cancelled"}
      
      assert {:interrupt, %{ref: "1", reason: "cancelled"}} = WebSocketHandler.parse_message(msg)
    end

    test "returns error for invalid message" do
      msg = %{"invalid" => "data"}
      
      assert {:error, :invalid_message} = WebSocketHandler.parse_message(msg)
    end
  end

  describe "thought formatting" do
    test "formats thought for broadcast" do
      thought = %{type: :reasoning, content: "Thinking about X"}
      
      formatted = WebSocketHandler.format_thought(thought, "ref1")
      
      assert formatted.type == "reasoning"
      assert formatted.content == "Thinking about X"
      assert formatted.ref == "ref1"
      assert formatted.timestamp
    end
  end
end
```

### Task 3: Integration Tests

**File**: `test/integration/websocket_integration_test.exs`

```elixir
defmodule Mimo.Integration.WebSocketIntegrationTest do
  use MimoWeb.ChannelCase
  
  @moduletag :integration

  alias MimoWeb.{UserSocket, CortexChannel}

  describe "full conversation flow" do
    setup do
      {:ok, _, socket} =
        socket(UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:session1", %{"api_key" => "test_key"})
      
      {:ok, socket: socket}
    end

    test "handles multiple queries in sequence", %{socket: socket} do
      # First query
      push(socket, "query", %{"q" => "Hello", "ref" => "q1"})
      assert_push "result", %{ref: "q1"}, 5000
      
      # Second query
      push(socket, "query", %{"q" => "Follow up", "ref" => "q2"})
      assert_push "result", %{ref: "q2"}, 5000
      
      # Third query
      push(socket, "query", %{"q" => "Another question", "ref" => "q3"})
      assert_push "result", %{ref: "q3"}, 5000
    end

    test "handles parallel queries", %{socket: socket} do
      # Send multiple queries at once
      push(socket, "query", %{"q" => "Query 1", "ref" => "p1"})
      push(socket, "query", %{"q" => "Query 2", "ref" => "p2"})
      push(socket, "query", %{"q" => "Query 3", "ref" => "p3"})
      
      # All should complete (order may vary)
      refs = for _ <- 1..3 do
        assert_push "result", %{ref: ref}, 10_000
        ref
      end
      
      assert "p1" in refs
      assert "p2" in refs
      assert "p3" in refs
    end
  end

  describe "error handling" do
    setup do
      {:ok, _, socket} =
        socket(UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:test", %{"api_key" => "test_key"})
      
      {:ok, socket: socket}
    end

    test "handles malformed JSON gracefully", %{socket: socket} do
      # This shouldn't crash the channel
      push(socket, "query", %{"malformed" => nil})
      
      assert_push "error", %{reason: _}, 1000
      
      # Channel should still work
      push(socket, "query", %{"q" => "Valid query", "ref" => "ok"})
      assert_push "result", %{ref: "ok"}, 5000
    end
  end

  describe "reconnection" do
    test "client can reconnect after disconnect" do
      # First connection
      {:ok, _, socket1} =
        socket(UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:session", %{"api_key" => "test_key"})
      
      # Disconnect
      Process.unlink(socket1.channel_pid)
      close(socket1)
      
      # Wait a bit
      Process.sleep(100)
      
      # Reconnect
      {:ok, _, socket2} =
        socket(UserSocket, "user:1", %{})
        |> subscribe_and_join(CortexChannel, "cortex:session", %{"api_key" => "test_key"})
      
      # Should work
      push(socket2, "query", %{"q" => "After reconnect", "ref" => "r1"})
      assert_push "result", %{ref: "r1"}, 5000
    end
  end
end
```

### Task 4: Load Testing

**File**: `bench/websocket_load_test.exs`

```elixir
defmodule WebSocketLoadTest do
  @moduledoc """
  Load test for WebSocket Synapse.
  
  Run with: mix run bench/websocket_load_test.exs
  """

  def run do
    IO.puts("=== WebSocket Synapse Load Test ===\n")
    
    # Start endpoint if not running
    ensure_endpoint_started()
    
    test_connection_throughput()
    test_message_throughput()
    test_concurrent_connections()
    test_memory_usage()
  end

  defp ensure_endpoint_started do
    case MimoWeb.Endpoint.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp test_connection_throughput do
    IO.puts("## Connection Throughput")
    
    {time, connections} = :timer.tc(fn ->
      for i <- 1..100 do
        {:ok, socket} = connect_socket(i)
        socket
      end
    end)
    
    rate = 100 / (time / 1_000_000)
    IO.puts("100 connections: #{Float.round(time/1000, 1)}ms")
    IO.puts("Rate: #{Float.round(rate, 1)} connections/sec")
    IO.puts("Target: > 100 connections/sec")
    IO.puts("Status: #{if rate > 100, do: "✅ PASS", else: "❌ FAIL"}\n")
    
    # Cleanup
    Enum.each(connections, &close_socket/1)
  end

  defp test_message_throughput do
    IO.puts("## Message Throughput")
    
    {:ok, socket} = connect_socket(1)
    
    {time, _} = :timer.tc(fn ->
      for i <- 1..1000 do
        send_query(socket, "Query #{i}", "q#{i}")
      end
      
      # Wait for all responses
      for i <- 1..1000 do
        receive do
          {:result, _} -> :ok
        after
          10_000 -> raise "Timeout waiting for response #{i}"
        end
      end
    end)
    
    rate = 1000 / (time / 1_000_000)
    IO.puts("1000 messages: #{Float.round(time/1000, 1)}ms")
    IO.puts("Rate: #{Float.round(rate, 1)} messages/sec")
    IO.puts("Target: > 1000 messages/sec")
    IO.puts("Status: #{if rate > 1000, do: "✅ PASS", else: "⚠️ SLOW"}\n")
    
    close_socket(socket)
  end

  defp test_concurrent_connections do
    IO.puts("## Concurrent Connections")
    
    target = 100
    
    tasks = for i <- 1..target do
      Task.async(fn ->
        {:ok, socket} = connect_socket(i)
        send_query(socket, "Hello from #{i}", "conn#{i}")
        
        receive do
          {:result, _} -> :ok
        after
          10_000 -> :timeout
        end
        
        close_socket(socket)
        :ok
      end)
    end
    
    results = Task.await_many(tasks, 60_000)
    success = Enum.count(results, &(&1 == :ok))
    
    IO.puts("Concurrent: #{success}/#{target} successful")
    IO.puts("Target: 100 concurrent")
    IO.puts("Status: #{if success >= 100, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp test_memory_usage do
    IO.puts("## Memory Usage")
    
    :erlang.garbage_collect()
    before_memory = :erlang.memory(:total)
    
    connections = for i <- 1..100 do
      {:ok, socket} = connect_socket(i)
      socket
    end
    
    after_memory = :erlang.memory(:total)
    per_connection = (after_memory - before_memory) / 100
    
    IO.puts("100 connections memory: #{Float.round((after_memory - before_memory) / 1_000_000, 2)}MB")
    IO.puts("Per connection: #{Float.round(per_connection / 1024, 2)}KB")
    IO.puts("Target: < 1MB per connection")
    IO.puts("Status: #{if per_connection < 1_000_000, do: "✅ PASS", else: "❌ FAIL"}\n")
    
    Enum.each(connections, &close_socket/1)
  end

  # Helper functions (simplified - actual implementation would use Phoenix.ChannelTest)
  defp connect_socket(id) do
    # In real test, use actual WebSocket client
    {:ok, %{id: id}}
  end

  defp send_query(socket, query, ref) do
    # In real test, send via WebSocket
    send(self(), {:result, %{ref: ref}})
    :ok
  end

  defp close_socket(_socket) do
    :ok
  end
end

# WebSocketLoadTest.run()
IO.puts("Note: Run this with actual WebSocket connections for real results")
```

### Task 5: JavaScript Client Test

**File**: `test/js/websocket_client_test.js`

```javascript
// WebSocket client integration test
// Run with: node test/js/websocket_client_test.js

const WebSocket = require('ws');

const WS_URL = process.env.WS_URL || 'ws://localhost:4000/cortex/websocket';
const API_KEY = process.env.API_KEY || 'test_key';

async function runTests() {
  console.log('=== WebSocket Client Tests ===\n');
  
  await testConnection();
  await testQuery();
  await testInterruption();
  await testReconnection();
  
  console.log('\n=== All Tests Complete ===');
}

async function testConnection() {
  console.log('## Connection Test');
  
  const start = Date.now();
  const ws = await connect();
  const elapsed = Date.now() - start;
  
  console.log(`Connection time: ${elapsed}ms`);
  console.log(`Target: < 100ms`);
  console.log(`Status: ${elapsed < 100 ? '✅ PASS' : '❌ FAIL'}\n`);
  
  ws.close();
}

async function testQuery() {
  console.log('## Query Test');
  
  const ws = await connect();
  
  const start = Date.now();
  const result = await sendQuery(ws, 'What is 2+2?', 'test1');
  const elapsed = Date.now() - start;
  
  console.log(`Query round-trip: ${elapsed}ms`);
  console.log(`Result: ${JSON.stringify(result).substring(0, 100)}...`);
  console.log(`Status: ${result.status === 'success' ? '✅ PASS' : '❌ FAIL'}\n`);
  
  ws.close();
}

async function testInterruption() {
  console.log('## Interruption Test');
  
  const ws = await connect();
  
  // Start query
  ws.send(JSON.stringify({
    event: 'query',
    payload: { q: 'Long query...', ref: 'int1' }
  }));
  
  // Interrupt after 100ms
  await sleep(100);
  ws.send(JSON.stringify({
    event: 'interrupt',
    payload: { ref: 'int1', reason: 'test' }
  }));
  
  // Wait for result
  const result = await waitForMessage(ws, 'result', 5000);
  
  console.log(`Interrupted: ${result.status === 'interrupted'}`);
  console.log(`Status: ${result.status === 'interrupted' ? '✅ PASS' : '⚠️ CHECK'}\n`);
  
  ws.close();
}

async function testReconnection() {
  console.log('## Reconnection Test');
  
  const ws1 = await connect();
  ws1.close();
  
  await sleep(100);
  
  const ws2 = await connect();
  const result = await sendQuery(ws2, 'After reconnect', 'recon1');
  
  console.log(`Reconnected and queried: ${result.status === 'success'}`);
  console.log(`Status: ${result.status === 'success' ? '✅ PASS' : '❌ FAIL'}\n`);
  
  ws2.close();
}

// Helpers
function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    
    ws.on('open', () => {
      // Join channel
      ws.send(JSON.stringify({
        event: 'phx_join',
        topic: 'cortex:test',
        payload: { api_key: API_KEY },
        ref: '1'
      }));
    });
    
    ws.on('message', (data) => {
      const msg = JSON.parse(data);
      if (msg.event === 'phx_reply' && msg.payload.status === 'ok') {
        resolve(ws);
      }
    });
    
    ws.on('error', reject);
    
    setTimeout(() => reject(new Error('Connection timeout')), 5000);
  });
}

function sendQuery(ws, query, ref) {
  return new Promise((resolve) => {
    ws.send(JSON.stringify({
      event: 'query',
      topic: 'cortex:test',
      payload: { q: query, ref },
      ref: ref
    }));
    
    const handler = (data) => {
      const msg = JSON.parse(data);
      if (msg.event === 'result' && msg.payload.ref === ref) {
        ws.removeListener('message', handler);
        resolve(msg.payload);
      }
    };
    
    ws.on('message', handler);
  });
}

function waitForMessage(ws, event, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timeout')), timeout);
    
    const handler = (data) => {
      const msg = JSON.parse(data);
      if (msg.event === event) {
        clearTimeout(timer);
        ws.removeListener('message', handler);
        resolve(msg.payload);
      }
    };
    
    ws.on('message', handler);
  });
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

runTests().catch(console.error);
```

---

## Acceptance Criteria

### Must Pass for ✅ Production Ready

1. **Connection**: Clients can connect and authenticate
2. **Messaging**: Queries processed and results returned
3. **Streaming**: Thoughts broadcast during processing
4. **Interruption**: Long-running queries can be cancelled
5. **Reliability**: No crashes on malformed input
6. **Performance**: 100+ concurrent connections, <10ms latency

### Optional for v1

- Presence tracking
- Message history/replay
- Rate limiting per connection

---

## Agent Prompt

```markdown
# WebSocket Synapse Validation Agent

## Mission
Validate WebSocket Synapse is production-ready for real-time AI communication.

## Tasks
1. Create test files as specified
2. Run channel and integration tests
3. Run load tests (if possible)
4. Test JavaScript client
5. Document results

## Success Criteria
- All connection/auth tests pass
- Query/response cycle works
- 100+ concurrent connections stable
- No crashes on bad input

## Output
Validation report with:
- Test results
- Performance metrics
- Any issues found
- Recommendation (✅ Ready / ⚠️ Beta / ❌ Broken)
```
