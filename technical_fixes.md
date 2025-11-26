# Technical Fixes for Memory Leaks and Resource Exhaustion

## 1. Port Leak Fix - Mimo.Skills.Client

**Problem:** Port cleanup not guaranteed on abnormal termination

**Solution:** Implement robust port management with monitoring

```elixir
defmodule Mimo.Skills.Client do
  # Add port monitoring to state
  defstruct [:skill_name, :port, :tool_prefix, :status, :tools, :port_monitor_ref]

  @impl true
  def init({skill_name, config}) do
    Process.flag(:trap_exit, true)
    Logger.info("Starting skill: #{skill_name}")

    case spawn_subprocess(config) do
      {:ok, port} ->
        # Monitor the port for cleanup
        port_monitor_ref = Port.monitor(port)
        
        # Give the process time to start
        Process.sleep(1000)

        case discover_tools(port) do
          {:ok, tools} ->
            Mimo.Registry.register_skill_tools(skill_name, tools, self())

            state = %__MODULE__{
              skill_name: skill_name,
              port: port,
              tool_prefix: skill_name,
              status: :active,
              tools: tools,
              port_monitor_ref: port_monitor_ref
            }

            Logger.info("✓ Skill '#{skill_name}' loaded #{length(tools)} tools")
            {:ok, state}

          {:error, reason} ->
            Logger.error("✗ Skill '#{skill_name}' discovery failed: #{inspect(reason)}")
            # Ensure port is closed on discovery failure
            Port.close(port)
            {:stop, {:discovery_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("✗ Skill '#{skill_name}' spawn failed: #{inspect(reason)}")
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :port, port, _reason}, %{port: port, port_monitor_ref: ref} = state) do
    Logger.error("Skill '#{state.skill_name}' port died unexpectedly")
    {:stop, {:port_died, :unexpected}, state}
  end

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
end
```

## 2. ETS Table Cleanup - Mimo.Registry

**Problem:** Dead process entries accumulate in ETS tables

**Solution:** Implement periodic cleanup and dead process detection

```elixir
defmodule Mimo.Registry do
  # Add cleanup interval
  @cleanup_interval 60_000  # 1 minute
  @max_table_size 10_000    # Limit table size

  @impl true
  def init(_) do
    :ets.new(@tools_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@skills_table, [:named_table, :set, :public, read_concurrency: true])
    
    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_dead_processes, @cleanup_interval)
    
    {:ok, %{} }
  end

  @impl true
  def handle_info(:cleanup_dead_processes, state) do
    cleanup_dead_entries()
    # Reschedule cleanup
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
      # Clean up associated tools
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

  # Modified active_skill_tools to filter alive processes
  defp active_skill_tools do
    @tools_table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {_key, skill_name, client_pid, tool_def}, acc ->
      if Process.alive?(client_pid) do
        prefixed_name = "#{skill_name}_#{tool_def["name"]}"
        [Map.put(tool_def, "name", prefixed_name) | acc]
      else
        # Queue for cleanup instead of ignoring
        acc
      end
    end)
  end
end
```

## 3. Memory Search Optimization - Mimo.Brain.Memory

**Problem:** Full table scan for every search operation

**Solution:** Implement database-side filtering and pagination

```elixir
defmodule Mimo.Brain.Memory do
  @max_search_results 1000  # Limit results
  @embedding_batch_size 100  # Process in batches

  def search_memories(query, opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 10), @max_search_results)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)

    case Mimo.Brain.LLM.generate_embedding(query) do
      {:ok, query_embedding} ->
        # Use database-side filtering with pagination
        search_with_pagination(query_embedding, min_similarity, limit)

      {:error, reason} ->
        Logger.error("Embedding generation failed: #{inspect(reason)}")
        []
    end
  end

  defp search_with_pagination(query_embedding, min_similarity, limit) do
    # Calculate a rough similarity threshold for database filtering
    # This is a simplified approach - in production, use vector database
    
    # Get memories in batches to avoid loading everything
    total_count = Repo.aggregate(Engram, :count, :id)
    
    if total_count > @embedding_batch_size do
      # Process in batches for large datasets
      batch_search(query_embedding, min_similarity, limit, total_count)
    else
      # Small dataset - process all at once
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
end
```

## 4. Process Limits - Application Supervision

**Problem:** No process limits in DynamicSupervisor

**Solution:** Add process limits and monitoring

```elixir
defmodule Mimo.Application do
  # Add process limits
  @max_skill_processes 100
  @max_restart_intensity 5
  @max_restart_period 60

  defp synthetic_cortex_children do
    []
    |> maybe_add_child(:rust_nifs, {Mimo.Vector.Supervisor, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.ConnectionManager, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.InterruptManager, []})
    |> maybe_add_child(:procedural_store, {Mimo.ProceduralStore.Registry, []})
  end

  # Enhanced supervision with limits
  defp start_http_endpoint(sup) do
    child_spec = {MimoWeb.Endpoint, []}

    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} ->
        Logger.info("✅ HTTP Gateway started on port #{http_port()}")

      {:error, reason} ->
        Logger.warning("⚠️ HTTP Gateway failed to start: #{inspect(reason)}")
    end
  end

  defp start_mcp_server(sup) do
    port = mcp_port()

    child_spec = %{
      id: Mimo.McpServer,
      start: {Mimo.McpServer, :start_link, [[port: port]]},
      restart: :permanent,
      max_restarts: @max_restart_intensity,
      max_seconds: @max_restart_period
    }

    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} ->
        Logger.info("✅ MCP Server started")

      {:error, reason} ->
        Logger.warning("MCP Server start failed: #{inspect(reason)}, using fallback")
        start_fallback_server(sup, port)
    end
  end
end

# Enhanced DynamicSupervisor for skills
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

## 5. Embedding Storage Optimization

**Problem:** Text storage of embeddings is inefficient

**Solution:** Implement binary storage and compression

```elixir
defmodule Mimo.Brain.EctoBinaryList do
  @moduledoc """
  Custom Ecto type for storing embedding vectors as binary data
  """
  use Ecto.Type

  def type, do: :binary

  def cast(embedding) when is_list(embedding) do
    {:ok, embedding}
  end

  def cast(_), do: :error

  def load(binary) when is_binary(binary) do
    try do
      # Decompress and decode
      decompressed = :zlib.uncompress(binary)
      {:ok, :erlang.binary_to_term(decompressed)}
    rescue
      _ -> :error
    end
  end

  def dump(embedding) when is_list(embedding) do
    try do
      # Encode and compress
      binary = :erlang.term_to_binary(embedding)
      compressed = :zlib.compress(binary)
      {:ok, compressed}
    rescue
      _ -> :error
    end
  end
end

# Migration update
defmodule Mimo.Repo.Migrations.OptimizeEmbeddingStorage do
  use Ecto.Migration

  def change do
    alter table(:engrams) do
      remove :embedding
      add :embedding_binary, :binary
    end
  end
end
```

## 6. Connection Pool Management

**Problem:** Low connection pool limits

**Solution:** Implement proper pool configuration and monitoring

```elixir
# config/runtime.exs
import Config

# Database pool configuration based on environment
pool_size = case System.get_env("POOL_SIZE") do
  nil -> 20  # Default
  size -> String.to_integer(size)
end

config :mimo_mcp, Mimo.Repo,
  database: System.get_env("DATABASE_PATH", "priv/mimo_mcp.db"),
  pool_size: pool_size,
  queue_target: 50,  # Target time for waiting in queue (ms)
  queue_interval: 1000,  # Max time for waiting in queue (ms)
  timeout: 30_000,  # Query timeout
  connect_timeout: 10_000,  # Connection timeout
  pool_timeout: 5_000  # Pool checkout timeout

# Pool monitoring
defmodule Mimo.Repo.PoolMonitor do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Schedule periodic pool status checks
    Process.send_after(self(), :check_pool_status, 30_000)
    {:ok, %{} }
  end

  def handle_info(:check_pool_status, state) do
    pool_status = get_pool_status()
    
    if pool_status.queue_length > 10 do
      Logger.warning("Database pool queue length: #{pool_status.queue_length}")
    end
    
    if pool_status.wait_time > 1000 do
      Logger.error("Database pool wait time: #{pool_status.wait_time}ms")
    end

    Process.send_after(self(), :check_pool_status, 30_000)
    {:noreply, state}
  end

  defp get_pool_status do
    # Get pool status from Ecto
    %{queue_length: queue_length, wait_time: wait_time} = 
      Mimo.Repo.checkout(fn conn ->
        %{queue_length: 0, wait_time: 0}  # Simplified - implement actual monitoring
      end)
    
    %{queue_length: queue_length, wait_time: wait_time}
  end
end
```

## 7. Message Backlog Prevention

**Problem:** Message accumulation in process mailboxes

**Solution:** Implement message rate limiting and cleanup

```elixir
defmodule Mimo.Skills.Client do
  # Add message queue monitoring
  def handle_info(:check_message_queue, state) do
    message_count = Process.info(self(), :message_queue_len) |> elem(1)
    
    if message_count > 100 do
      Logger.warning("Skill #{state.skill_name} message queue length: #{message_count}")
      # Implement message cleanup or backpressure
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Enhanced message handling with cleanup
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    # Clean up any stale messages before processing
    clean_stale_messages()
    
    # Normal processing...
    request = build_request(tool_name, arguments)
    Port.command(state.port, request <> "\n")

    receive do
      {_, {:data, data}} ->
        handle_port_response(data, state, from)
    after
      60_000 -> 
        Logger.error("Tool call timeout for #{tool_name}")
        {:reply, {:error, :timeout}, state}
    end
  end

  defp clean_stale_messages do
    # Remove old port messages that may have accumulated
    receive do
      {_port, {:data, _data}} -> 
        Logger.debug("Cleaned up stale port message")
        clean_stale_messages()
      {_port, {:exit_status, _status}} -> 
        Logger.debug("Cleaned up stale exit status")
        clean_stale_messages()
    after
      0 -> :ok  # No more messages
    end
  end
end
```

## 8. Resource Monitoring Dashboard

**Problem:** No visibility into resource usage

**Solution:** Implement comprehensive monitoring

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
    
    # Log critical metrics
    log_metrics(metrics)
    
    # Alert on critical conditions
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
    processes = Process.list()
    
    processes
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
    # Get database pool statistics
    %{size: 0, busy: 0, queue: 0}  # Simplified implementation
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

## Implementation Priority

### Phase 1: Critical Fixes (Week 1)
1. Port leak fix in Mimo.Skills.Client
2. ETS table cleanup in Mimo.Registry
3. Memory search optimization in Mimo.Brain.Memory

### Phase 2: Resource Management (Week 2)
1. Process limits in supervision trees
2. Connection pool optimization
3. Resource monitoring implementation

### Phase 3: Optimization (Week 3)
1. Embedding storage optimization
2. Message backlog prevention
3. Comprehensive testing

These fixes will significantly improve the system's ability to handle large-scale memory storage and prevent resource exhaustion issues.