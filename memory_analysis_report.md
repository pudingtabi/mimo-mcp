# Mimo Memory Leak and Resource Exhaustion Analysis

## Executive Summary

This report identifies critical memory leaks and resource exhaustion vulnerabilities in the Mimo MCP system. The analysis reveals several high-risk issues that could lead to system instability under load, particularly with large-scale memory storage (10K+ memories).

## Critical Issues Found

### 1. Port Leaks - HIGH RISK ⚠️

**File:** `/root/mimo/mimo_mcp/lib/mimo/skills/client.ex`

**Issue:** Port cleanup in `terminate/2` is not guaranteed on abnormal shutdown

**Problems:**
- Line 287-294: Port closure only happens in normal termination
- If GenServer crashes abnormally, `terminate/2` may not be called
- Port processes can become zombie processes
- No monitoring of port health/status

**Code Analysis:**
```elixir
def terminate(_reason, state) do
  if state.port do
    Port.close(state.port)  # Only closes on normal termination
  end
  Mimo.Registry.unregister_skill(state.skill_name)
  :ok
end
```

**Fix Required:**
```elixir
def terminate(_reason, state) do
  if state.port do
    try do
      Port.close(state.port)
    catch
      :error, _ -> :ok  # Port already dead
    end
  end
  Mimo.Registry.unregister_skill(state.skill_name)
  :ok
end
```

### 2. ETS Table Growth - CRITICAL RISK 🚨

**Files:** 
- `/root/mimo/mimo_mcp/lib/mimo/registry.ex`
- `/root/mimo/mimo_mcp/lib/mimo/synapse/connection_manager.ex`
- `/root/mimo/mimo_mcp/lib/mimo/synapse/interrupt_manager.ex`
- `/root/mimo/mimo_mcp/lib/mimo/skills/catalog.ex`

**Issue:** Multiple ETS tables with no cleanup or size limits

**Vulnerable Tables:**
1. `:mimo_tools` - Tool registrations (line 9 in registry.ex)
2. `:mimo_skills` - Skill process tracking (line 10 in registry.ex)
3. `:synapse_connections` - WebSocket connections (line 13 in connection_manager.ex)
4. `:synapse_interrupts` - Interrupt signals (line 12 in interrupt_manager.ex)
5. `:mimo_skill_catalog` - Skill catalog (line 9 in catalog.ex)

**Problems:**
- No cleanup of dead process entries
- No table size monitoring
- No eviction policies
- Zombie process references accumulate

**Registry.zombie_process_accumulation:**
```elixir
# Line 164-171 in registry.ex
|> Enum.reduce([], fn {_key, skill_name, client_pid, tool_def}, acc ->
  if Process.alive?(client_pid) do
    prefixed_name = "#{skill_name}_#{tool_def["name"]}"
    [Map.put(tool_def, "name", prefixed_name) | acc]
  else
    acc  # DEAD PROCESS ENTRIES ACCUMULATE HERE
  end
end)
```

### 3. Process Leaks - HIGH RISK ⚠️

**Files:**
- `/root/mimo/mimo_mcp/lib/mimo/skills/client.ex`
- `/root/mimo/mimo_mcp/lib/mimo/procedural_store/execution_fsm.ex`

**Issues:**
1. **Skill Client Processes:** No cleanup verification in lazy-spawn mechanism
2. **Execution FSM Processes:** No process limit or cleanup verification

**Skill Process Leak (client.ex:38-51):**
```elixir
defp spawn_and_call(skill_name, config, tool_name, arguments) do
  child_spec = %{
    id: {__MODULE__, skill_name},
    start: {__MODULE__, :start_link, [skill_name, config]},
    restart: :transient,
    shutdown: 30_000
  }

  case DynamicSupervisor.start_child(Mimo.Skills.Supervisor, child_spec) do
    {:ok, _pid} -> call_tool(skill_name, tool_name, arguments)
    {:error, {:already_started, _pid}} -> call_tool(skill_name, tool_name, arguments)
    {:error, reason} -> {:error, reason}
  end
end
```
**Problem:** No verification that stopped processes are actually cleaned up

### 4. Memory Ballooning - CRITICAL RISK 🚨

**File:** `/root/mimo/mimo_mcp/lib/mimo/brain/memory.ex`

**Issue:** Full table scan for every memory search operation

**Critical Code (lines 22-37):**
```elixir
def search_memories(query, opts \ []) do
  limit = Keyword.get(opts, :limit, 10)
  _min_similarity = Keyword.get(opts, :min_similarity, 0.3)

  case Mimo.Brain.LLM.generate_embedding(query) do
    {:ok, query_embedding} ->
      # Get ALL memories and calculate similarity in Elixir
      memories = Repo.all(Engram)  # FULL TABLE SCAN - O(n) MEMORY

      memories
      |> Enum.map(fn engram ->
        similarity = calculate_similarity(query_embedding, engram.embedding)
        %{
          id: engram.id,
          content: engram.content,
          category: engram.category,
          importance: engram.importance,
          similarity: similarity
        }
      end)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)
```

**Memory Impact Analysis:**
- 10K memories: ~50-100MB loaded into memory per search
- 100K memories: ~500MB-1GB loaded into memory per search
- 1M memories: ~5-10GB loaded into memory per search

**Missing Optimizations:**
- No database-side filtering
- No pagination
- No similarity threshold application before loading
- No embedding index

### 5. Connection Pool Exhaustion - MEDIUM RISK ⚠️

**File:** `/root/mimo/mimo_mcp/config/dev.exs` and `/root/mimo/mimo_mcp/lib/mimo/repo.ex`

**Issue:** SQLite with default pool size of 5 connections

**Configuration:**
```elixir
config :mimo_mcp, Mimo.Repo,
  database: "priv/mimo_mcp_dev.db",
  pool_size: 5,  # VERY LOW FOR PRODUCTION
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
```

**Risk:** Under high concurrency, connection pool exhaustion could cause database operations to fail

### 6. Binary Memory - HIGH RISK ⚠️

**Files:**
- `/root/mimo/mimo_mcp/lib/mimo/brain/engram.ex`
- `/root/mimo/mimo_mcp/lib/mimo/brain/ecto_types.ex`

**Issue:** Large embedding binaries stored as JSON text

**Problems:**
- Embeddings stored as JSON strings (line 10 in engram migration)
- No binary memory optimization
- Large binaries not garbage collected efficiently
- No compression for embeddings

**Storage Format:**
```elixir
# Line 10 in migration
add :embedding, :text, default: "[]"  # JSON array as text - INEFFICIENT
```

### 7. Message Backlog - MEDIUM RISK ⚠️

**Files:**
- `/root/mimo/mimo_mcp/lib/mimo/skills/client.ex`
- `/root/mimo/mimo_mcp/lib/mimo/synapse/message_router.ex`

**Issues:**
1. **Port Messages:** No cleanup of port message queues on termination
2. **PubSub Messages:** No backpressure or message rate limiting

**Port Message Handling (client.ex:251-260):**
```elixir
receive do
  {_, {:data, data}} ->
    case Jason.decode(data) do
      {:ok, %{"result" => result}} -> {:reply, {:ok, result}, state}
      {:ok, %{"error" => error}} -> {:reply, {:error, error}, state}
      {:error, _} -> {:reply, {:error, :invalid_response}, state}
    end
after
  60_000 -> {:reply, {:error, :timeout}, state}
end
```
**Problem:** Messages can accumulate in process mailbox during timeouts

### 8. Embedding Storage Bloat - HIGH RISK ⚠️

**File:** `/root/mimo/mimo_mcp/lib/mimo/brain/engram.ex`

**Issue:** Text storage of embeddings causing memory bloat

**Current Storage:**
```elixir
# Line 16-17 in engram.ex
field(:embedding, Mimo.Brain.EctoJsonList, default: [])  # JSON text
field(:metadata, Mimo.Brain.EctoJsonMap, default: %{})  # JSON text
```

**Memory Impact:**
- Each embedding vector (1536 dimensions) = ~12KB as JSON text
- 10K memories = ~120MB of embedding storage
- 100K memories = ~1.2GB of embedding storage
- 1M memories = ~12GB of embedding storage

## Memory Usage Estimates

### Current Architecture (with identified issues):

| Memories | Memory Usage | Primary Consumers |
|----------|-------------|-------------------|
| 10K | 500MB-1GB | • Full table scans (50-100MB/search)<br>• ETS tables (10-50MB)<br>• Process overhead (100-200MB)<br>• Embedding storage (120MB) |
| 100K | 5-10GB | • Full table scans (500MB-1GB/search)<br>• ETS table bloat (100-500MB)<br>• Process leaks (1-2GB)<br>• Embedding storage (1.2GB) |
| 1M | 50-100GB | • Full table scans (5-10GB/search)<br>• ETS table explosion (1-5GB)<br>• Process chaos (10-20GB)<br>• Embedding storage (12GB) |

### Fixed Architecture (projected):

| Memories | Memory Usage | Improvements |
|----------|-------------|--------------|
| 10K | 50-100MB | • Database-side filtering<br>• ETS cleanup<br>• Process limits<br>• Binary storage |
| 100K | 500MB-1GB | • Indexed queries<br>• Memory-efficient ETS<br>• Process pooling<br>• Compressed embeddings |
| 1M | 5-10GB | • Vector database integration<br>• Automatic cleanup<br>• Resource limits<br>• Optimal storage |

## Application Supervision Tree Analysis

**File:** `/root/mimo/mimo_mcp/lib/mimo/application.ex`

### Current Supervision Structure:
```
Mimo.Supervisor
├── Mimo.Repo (Database)
├── Registry (Skill lookups)
├── Mimo.Registry (ETS-based tool routing)
├── Mimo.Skills.Catalog (Static catalog)
├── Task.Supervisor (Async operations)
├── DynamicSupervisor (Skill processes)
├── Mimo.Telemetry (Metrics)
└── Synthetic Cortex Modules (Conditional)
    ├── Mimo.Vector.Supervisor (Rust NIFs)
    ├── Mimo.Synapse.ConnectionManager (WebSocket)
    └── Mimo.Synapse.InterruptManager (Interrupts)
```

### Supervision Issues:

1. **No Process Limits:** DynamicSupervisor has no max_children limit
2. **No Restart Limits:** Transient restart strategy could lead to restart loops
3. **Missing Health Checks:** No process health monitoring
4. **No Resource Monitoring:** No memory or CPU monitoring

### Recommended Supervision Improvements:

```elixir
# Add process limits and monitoring
{DynamicSupervisor, 
  strategy: :one_for_one, 
  name: Mimo.Skills.Supervisor,
  max_children: 100,  # LIMIT PROCESSES
  max_restarts: 5,    # PREVENT RESTART LOOPS
  max_seconds: 60}
```

## Critical Recommendations

### Immediate Actions (High Priority):

1. **Fix Memory Search Performance**
   - Add database-side similarity filtering
   - Implement embedding indexes
   - Add pagination and result limiting

2. **Implement ETS Table Cleanup**
   - Add dead process detection
   - Implement periodic cleanup
   - Add table size monitoring

3. **Fix Port Cleanup**
   - Implement robust port termination
   - Add port health monitoring
   - Implement port resource limits

### Medium-Term Actions:

1. **Implement Process Limits**
   - Add DynamicSupervisor limits
   - Implement process pooling
   - Add resource monitoring

2. **Optimize Embedding Storage**
   - Implement binary storage
   - Add compression
   - Optimize memory layout

3. **Add Connection Pool Management**
   - Increase pool sizes
   - Add pool monitoring
   - Implement connection health checks

### Long-Term Architecture Changes:

1. **Vector Database Integration**
   - Replace SQLite for embeddings
   - Implement efficient similarity search
   - Add vector indexing

2. **Resource Monitoring System**
   - Add comprehensive metrics
   - Implement alerting
   - Add automatic scaling

3. **Process Lifecycle Management**
   - Implement graceful shutdown
   - Add process health monitoring
   - Implement resource limits

## Conclusion

The Mimo system has several critical memory leaks and resource exhaustion vulnerabilities that make it unsuitable for production use with large memory datasets. The most critical issues are:

1. **Unbounded ETS table growth** - Could crash the VM
2. **Full table scans in memory search** - Linear memory growth with data size
3. **Port cleanup failures** - Could lead to zombie OS processes
4. **Process leaks** - Could exhaust process limits

These issues need immediate attention before the system can handle production workloads with significant memory storage requirements.