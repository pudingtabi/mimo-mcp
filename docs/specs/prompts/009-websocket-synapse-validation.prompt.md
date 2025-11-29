# Agent Prompt: SPEC-009 WebSocket Synapse Production Validation

## Mission
Validate WebSocket Synapse for real-time bidirectional communication. Transform status from "⚠️ Beta" to "✅ Production Ready".

## Context
- **Workspace**: `/workspace/mrc-server/mimo-mcp`
- **Spec**: `docs/specs/009-websocket-synapse-validation.md`
- **Target Modules**: `lib/mimo/synapse/*.ex`, `lib/mimo_web/channels/`
- **Test Location**: `test/mimo/synapse/`

## Phase 1: Connection Lifecycle Testing

### Task 1.1: Connection Test Suite
Create `test/mimo/synapse/connection_test.exs`:

```elixir
# Test connection lifecycle:
# 1. Connect with valid token
# 2. Connect with invalid token (reject)
# 3. Connect without token (reject)
# 4. Reconnect after disconnect
# 5. Multiple connections same client
# 6. Connection timeout handling
```

**Test Cases:**
- [ ] Successful authentication
- [ ] Invalid token rejection
- [ ] Graceful disconnect
- [ ] Reconnection within 30s
- [ ] Max connections per client (10)

### Task 1.2: Heartbeat/Keepalive Test
Create `test/mimo/synapse/heartbeat_test.exs`:

```elixir
# Test heartbeat mechanism:
# 1. Client sends ping, server responds pong
# 2. Server detects dead connection (no heartbeat)
# 3. Auto-disconnect after 60s no heartbeat
```

## Phase 2: Message Protocol Testing

### Task 2.1: Query/Response Flow
Create `test/mimo/synapse/query_test.exs`:

```elixir
# Test query flow:
# 1. Client sends query
# 2. Server streams thoughts (multiple messages)
# 3. Server sends final result
# 4. Client can interrupt mid-stream
```

Message types to test:
- [ ] `query` → `thought` → `thought` → `result`
- [ ] `query` → `interrupt` → `interrupted`
- [ ] `query` → `error`

### Task 2.2: Tool Execution via WebSocket
Create `test/mimo/synapse/tool_test.exs`:

```elixir
# Test tool execution:
# 1. Execute tool via WebSocket
# 2. Receive progress updates
# 3. Receive final result
# 4. Handle tool errors
```

### Task 2.3: PubSub Broadcast Test
Create `test/mimo/synapse/pubsub_test.exs`:

```elixir
# Test broadcast:
# 1. Subscribe to topic
# 2. Receive broadcasts from other connections
# 3. Unsubscribe
# 4. No messages after unsubscribe
```

## Phase 3: Load Testing

### Task 3.1: Concurrent Connections Benchmark
Create `bench/synapse/connection_load.exs`:

```elixir
# Test concurrent connections:
# - 100 simultaneous connections
# - 500 simultaneous connections
# - 1000 simultaneous connections
# 
# Measure:
# - Connection time
# - Memory per connection
# - Message latency under load
```

**Targets:**
- [ ] 100 connections: < 1s total connect time
- [ ] 500 connections: < 5s total connect time
- [ ] Message latency: < 50ms at 100 connections
- [ ] Memory: < 1MB per connection

### Task 3.2: Message Throughput Benchmark
Create `bench/synapse/message_throughput.exs`:

```elixir
# Test message throughput:
# - 100 messages/second sustained
# - 1000 messages burst
# - Broadcast to 100 subscribers
```

**Targets:**
- [ ] 100 msg/s sustained: no drops
- [ ] 1000 msg burst: < 1s to deliver all
- [ ] Broadcast latency: < 10ms to all subscribers

## Phase 4: Error Handling & Recovery

### Task 4.1: Error Scenarios Test
Create `test/mimo/synapse/error_handling_test.exs`:

```elixir
# Test error scenarios:
# 1. Malformed JSON message
# 2. Unknown message type
# 3. Missing required fields
# 4. Oversized message (> 1MB)
# 5. Rate limit exceeded
```

### Task 4.2: Crash Recovery Test
Create `test/mimo/synapse/crash_recovery_test.exs`:

```elixir
# Test crash recovery:
# 1. Channel process crashes
# 2. Client auto-reconnects
# 3. State restored (subscriptions)
```

### Task 4.3: Rate Limiting
Implement and test `lib/mimo/synapse/rate_limiter.ex`:

```elixir
defmodule Mimo.Synapse.RateLimiter do
  # Per-connection rate limiting
  # - 60 messages/minute
  # - 10 queries/minute
  # - Burst allowance: 20 messages
end
```

## Phase 5: Security Hardening

### Task 5.1: Authentication Test
Create `test/mimo/synapse/auth_test.exs`:

```elixir
# Test authentication:
# 1. Valid API key → connect
# 2. Invalid API key → reject
# 3. Expired token → reject
# 4. Token refresh flow
```

### Task 5.2: Input Validation
Create `test/mimo/synapse/validation_test.exs`:

```elixir
# Test input validation:
# 1. SQL injection attempts
# 2. XSS payloads
# 3. Path traversal
# 4. Command injection
```

### Task 5.3: Connection Limits
Implement limits:
- [ ] Max connections per IP: 100
- [ ] Max connections per API key: 10
- [ ] Connection rate limit: 10/minute per IP

## Phase 6: Client SDK Stub

### Task 6.1: JavaScript Client Example
Create `examples/websocket/client.js`:

```javascript
// Example WebSocket client for Mimo Synapse
class MimoSynapse {
  constructor(url, apiKey) { ... }
  connect() { ... }
  query(q, onThought, onResult) { ... }
  interrupt(ref) { ... }
  subscribe(topic, callback) { ... }
  disconnect() { ... }
}
```

### Task 6.2: Python Client Example
Create `examples/websocket/client.py`:

```python
# Example WebSocket client for Mimo Synapse
class MimoSynapse:
    def __init__(self, url, api_key): ...
    async def connect(self): ...
    async def query(self, q): ...
    async def interrupt(self, ref): ...
```

## Phase 7: Validation Report

### Task 7.1: Generate Report
Create `docs/verification/websocket-synapse-validation-report.md`:

```markdown
# WebSocket Synapse Production Validation Report

## Connection Tests
- Authentication: ✅
- Reconnection: ✅
- Heartbeat: ✅

## Protocol Tests
- Query/Response: ✅
- Tool Execution: ✅
- PubSub: ✅

## Load Tests
| Metric | Target | Actual |
|--------|--------|--------|
| Max Connections | 500 | X |
| Message Latency | <50ms | Xms |
| Throughput | 100 msg/s | X msg/s |

## Security
- Auth: ✅
- Rate Limiting: ✅
- Input Validation: ✅

## Recommendation
[READY/NOT READY] for production
```

## Execution Order

```
1. Phase 1 (Connection) - Basic lifecycle
2. Phase 2 (Protocol) - Message handling
3. Phase 3 (Load) - Performance
4. Phase 4 (Errors) - Robustness
5. Phase 5 (Security) - Hardening
6. Phase 6 (SDK) - Client examples
7. Phase 7 (Report) - Documentation
```

## Success Criteria

All must be GREEN:
- [ ] Connection lifecycle tests pass
- [ ] All message types handled correctly
- [ ] 500+ concurrent connections supported
- [ ] < 50ms message latency
- [ ] Rate limiting works
- [ ] Auth/security tests pass
- [ ] Client examples provided
- [ ] Validation report generated

## Commands

```bash
# Run synapse tests
mix test test/mimo/synapse/

# Run load test
mix run bench/synapse/connection_load.exs

# Run throughput test
mix run bench/synapse/message_throughput.exs

# Test WebSocket manually
websocat ws://localhost:4000/cortex/websocket
```

## Notes for Agent

1. **Start with existing tests** - check what's already covered
2. **Use Phoenix.ChannelTest** for unit tests
3. **Use websocket client for integration tests**
4. **Document actual performance numbers**
5. **Client SDKs are examples, not full libraries**
