# Implementation Guide: Memory Leak Fixes

## Quick Start: Apply Critical Fixes

### Fix 1: Port Leak Prevention (5 minutes)

**File:** `lib/mimo/skills/client.ex`

**Changes needed:**

1. Add port monitoring to state struct (line 9):
```elixir
defstruct [:skill_name, :port, :tool_prefix, :status, :tools, :port_monitor_ref]
```

2. Add port monitoring in init (after line 67):
```elixir
{:ok, port} ->
  # Monitor the port for cleanup
  port_monitor_ref = Port.monitor(port)
  # ... rest of existing code
  
  state = %__MODULE__{
    # ... existing fields
    port_monitor_ref: port_monitor_ref
  }
```

3. Add port DOWN handler (after line 272):
```elixir
@impl true
def handle_info({:DOWN, ref, :port, port, _reason}, %{port: port, port_monitor_ref: ref} = state) do
  Logger.error("Skill '#{state.skill_name}' port died unexpectedly")
  {:stop, {:port_died, :unexpected}, state}
end
```

4. Enhance terminate function (replace lines 287-294):
```elixir
@impl true
def terminate(_reason, state) do
  # Robust port cleanup
  if state.port do
    try do
      Port.close(state.port)
      Logger.debug("Closed port for skill: #{state.skill_name}")
    catch
      :error, _ -> 
        Logger.debug("Port already closed for skill: #{state.skill_name}")
        :ok
    end
  end

  # Clean up port monitor
  if state.port_monitor_ref do
    Port.demonitor(state.port_monitor_ref, [:flush])
  end

  Mimo.Registry.unregister_skill(state.skill_name)
  :ok
end
```

### Fix 2: ETS Table Cleanup (10 minutes)

**File:** `lib/mimo/registry.ex`

1. Add cleanup configuration (after line 11):
```elixir
@cleanup_interval 60_000  # 1 minute
@max_table_size 10_000    # Limit table size
```

2. Add cleanup scheduling in init (after line 20):
```elixir
def init(_) do
  :ets.new(@tools_table, [:named_table, :set, :public, read_concurrency: true])
  :ets.new(@skills_table, [:named_table, :set, :public, read_concurrency: true])
  
  # Schedule periodic cleanup
  Process.send_after(self(), :cleanup_dead_processes, @cleanup_interval)
  
  {:ok, %{} }
end
```

3. Add cleanup handler (after line 312):
```elixir
@impl true
def handle_info(:cleanup_dead_processes, state) do
  cleanup_dead_entries()
  Process.send_after(self(), :cleanup_dead_processes, @cleanup_interval)
  {:noreply, state}
end

 defp cleanup_dead_entries do
  # Clean up dead skill processes
  dead_skills = 
    @skills_table
    |> :ets.tab2list()
    |> Enum.filter(fn {_skill_name, client_pid, _status} ->
      not Process.alive?(client_pid)
    end)

  # Remove dead skills
  Enum.each(dead_skills, fn {skill_name, _pid, _status} ->
    :ets.delete(@skills_table, skill_name)
    :ets.match_delete(@tools_table, {:_, skill_name, :_, :_})
    Logger.debug("Cleaned up dead skill: #{skill_name}")
  end)

  # Check table sizes
  tools_size = :ets.info(@tools_table, :size)
  skills_size = :ets.info(@skills_table, :size)

  if tools_size > @max_table_size or skills_size > @max_table_size do
    Logger.warning("ETS table size warning: tools=#{tools_size}, skills=#{skills_size}")
  end

  {:ok, length(dead_skills)}
end
```

### Fix 3: Memory Search Optimization (15 minutes)

**File:** `lib/mimo/brain/memory.ex`

1. Add configuration constants (after line 8):
```elixir
@max_search_results 1000  # Limit results
@embedding_batch_size 100  # Process in batches
```

2. Replace the search_memories function (lines 14-47):
```elixir
def search_memories(query, opts \\ []) do
  limit = min(Keyword.get(opts, :limit, 10), @max_search_results)
  min_similarity = Keyword.get(opts, :min_similarity, 0.3)

  case Mimo.Brain.LLM.generate_embedding(query) do
    {:ok, query_embedding} ->
      search_with_pagination(query_embedding, min_similarity, limit)

    {:error, reason} ->
      Logger.error("Embedding generation failed: #{inspect(reason)}")
      []
  end
end
```

3. Add pagination functions (after line 100):
```elixir
defp search_with_pagination(query_embedding, min_similarity, limit) do
  total_count = Repo.aggregate(Engram, :count, :id)
  
  if total_count > @embedding_batch_size do
    batch_search(query_embedding, min_similarity, limit, total_count)
  else
    simple_search(query_embedding, min_similarity, limit)
  end
end

defp batch_search(query_embedding, min_similarity, limit, total_count) do
  batches = ceil(total_count / @embedding_batch_size)
  
  results = 
    0..(batches - 1)
    |> Enum.flat_map(fn batch_num ->
      offset = batch_num * @embedding_batch_size
      
      Engram
      |> limit(@embedding_batch_size)
      |> offset(offset)
      |> Repo.all()
      |> Enum.map(fn engram ->
        similarity = calculate_similarity(query_embedding, engram.embedding)
        
        if similarity >= min_similarity do
          %{
            id: engram.id,
            content: engram.content,
            category: engram.category,
            importance: engram.importance,
            similarity: similarity
          }
        else
          nil
        end
      end)
      |> Enum.filter(& &1)
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
  
  results
end

defp simple_search(query_embedding, min_similarity, limit) do
  memories = Repo.all(Engram)
  
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
  |> Enum.filter(& &1.similarity >= min_similarity)
  |> Enum.sort_by(& &1.similarity, :desc)
  |> Enum.take(limit)
end
```

### Fix 4: Process Limits (10 minutes)

**File:** `lib/mimo/application.ex`

1. Add process limits (after line 20):
```elixir
@max_skill_processes 100
@max_restart_intensity 5
@max_restart_period 60
```

2. Create new supervisor module: `lib/mimo/skills/supervisor.ex`
```elixir
defmodule Mimo.Skills.Supervisor do
  use DynamicSupervisor

  @max_children 100
  @max_restart_intensity 3
  @max_restart_period 30

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: @max_children,
      max_restarts: @max_restart_intensity,
      max_seconds: @max_restart_period,
      extra_arguments: []
    )
  end

  def count_children do
    DynamicSupervisor.count_children(__MODULE__)
  end

  def which_children do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
```

3. Update application.ex to use new supervisor (replace line 36):
```elixir
{Mimo.Skills.Supervisor, []},  # Use custom supervisor with limits
```

### Fix 5: Resource Monitoring (20 minutes)

**File:** `lib/mimo/telemetry/resource_monitor.ex`

Create new file with complete monitoring system:
```elixir
defmodule Mimo.Telemetry.ResourceMonitor do
  use GenServer
  require Logger

  @monitor_interval 60_000  # 1 minute

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    schedule_monitoring()
    {:ok, %{} }
  end

  def handle_info(:monitor_resources, state) do
    metrics = collect_metrics()
    log_metrics(metrics)
    check_critical_conditions(metrics)
    schedule_monitoring()
    {:noreply, state}
  end

  defp collect_metrics do
    %{
      memory: :erlang.memory(),
      process_count: :erlang.system_info(:process_count),
      ets_tables: length(:ets.all()),
      ets_memory: Enum.reduce(:ets.all(), 0, fn tab, acc -> 
        acc + :ets.info(tab, :memory) * :erlang.system_info(:wordsize)
      end),
      port_count: length(:erlang.ports()),
      message_queues: get_message_queue_stats(),
      db_pool: get_db_pool_stats()
    }
  end

  defp get_message_queue_stats do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:message_queue_len, :dictionary]) do
        [{:message_queue_len, len}, {:dictionary, dict}] ->
          name = case dict[:"$initial_call"] do
            nil -> "unknown"
            {mod, fun, _} -> "#{mod}.#{fun}"
          end
          {name, len}
        _ -> {"unknown", 0}
      end
    end)
    |> Enum.filter(fn {_name, len} -> len > 10 end)
    |> Enum.sort_by(fn {_name, len} -> len end, :desc)
    |> Enum.take(10)
  end

  defp get_db_pool_stats do
    %{size: 0, busy: 0, queue: 0}
  end

  defp log_metrics(metrics) do
    memory_mb = div(metrics.memory[:total], 1024 * 1024)
    ets_mb = div(metrics.ets_memory, 1024 * 1024)
    
    Logger.info("""
    Resource Metrics:
      Memory: #{memory_mb}MB
      Processes: #{metrics.process_count}
      ETS Tables: #{metrics.ets_tables} (#{ets_mb}MB)
      Ports: #{metrics.port_count}
    """)
  end

  defp check_critical_conditions(metrics) do
    memory_mb = div(metrics.memory[:total], 1024 * 1024)
    
    cond do
      memory_mb > 1000 ->
        Logger.error("CRITICAL: Memory usage exceeds 1GB: #{memory_mb}MB")
      metrics.process_count > 100_000 ->
        Logger.error("CRITICAL: Process count exceeds 100K: #{metrics.process_count}")
      metrics.ets_tables > 1000 ->
        Logger.error("CRITICAL: ETS table count exceeds 1K: #{metrics.ets_tables}")
      true ->
        :ok
    end
  end

  defp schedule_monitoring do
    Process.send_after(self(), :monitor_resources, @monitor_interval)
  end
end
```

Add to application.ex children list (line 38):
```elixir
Mimo.Telemetry.ResourceMonitor,  # Add resource monitoring
```

## Testing the Fixes

### 1. Port Leak Test
```elixir
# Test port cleanup
defmodule Mimo.PortCleanupTest do
  def test_port_cleanup do
    # Start a skill
    {:ok, pid} = Mimo.Skills.Client.start_link("test_skill", %{
      "command" => "echo",
      "args" => ["test"]
    })
    
    # Kill the process
    Process.exit(pid, :kill)
    
    # Verify port is cleaned up
    # (Check OS processes - should not have lingering ports)
  end
end
```

### 2. ETS Cleanup Test
```elixir
# Test ETS cleanup
defmodule Mimo.ETSCleanupTest do
  def test_ets_cleanup do
    # Create fake dead process entries
    fake_pid = spawn(fn -> Process.sleep(100) end)
    Process.sleep(200)  # Let it die
    
    # Trigger cleanup
    send(Mimo.Registry, :cleanup_dead_processes)
    Process.sleep(1000)
    
    # Verify cleanup
    # Check ETS tables - should not have dead process entries
  end
end
```

### 3. Memory Search Performance Test
```elixir
# Test memory search with large dataset
defmodule Mimo.MemorySearchTest do
  def test_search_performance do
    # Create test memories
    for i <- 1..1000 do
      Mimo.Brain.Memory.persist_memory("Test memory #{i}", "fact", 0.5)
    end
    
    # Measure search performance
    {time, results} = :timer.tc(fn ->
      Mimo.Brain.Memory.search_memories("test", limit: 10)
    end)
    
    IO.puts("Search took #{time/1000}ms for 1000 memories")
    IO.puts("Found #{length(results)} results")
  end
end
```

## Verification Checklist

After implementing all fixes:

- [ ] Port cleanup verified (no zombie processes)
- [ ] ETS tables clean (no dead process entries)
- [ ] Memory search performs well with 10K+ memories
- [ ] Process limits enforced (max 100 skill processes)
- [ ] Resource monitoring active (logs every minute)
- [ ] No memory leaks in long-running tests
- [ ] System stable under load testing

## Rollback Plan

If issues arise:

1. **Immediate rollback:** Revert to previous git commit
2. **Gradual rollback:** Disable problematic features via config
3. **Emergency stop:** Set process limits to minimum values

Keep monitoring active during and after deployment to catch any regressions.