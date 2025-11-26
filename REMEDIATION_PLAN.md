# Mimo MCP Gateway Remediation Plan v3.0
**From 3/10 to Production-Ready: Comprehensive System Hardening Roadmap**

---

## Executive Summary

This plan transforms Mimo MCP Gateway from a fragile prototype with critical security flaws into enterprise-grade software through **four major phases** over 12-16 weeks. Each phase delivers independently shippable improvements while building toward a complete, secure, and performant system.

**Current State**: 3/10 - Multiple critical vulnerabilities, race conditions, memory failures, and false advertising  
**Target State**: 10/10 - Production-hardened, secure, performant, with all advertised features functional

**Total Estimated Effort**: 1,200-1,600 developer-hours  
**Recommended Team**: 3 engineers (1 security/backend, 1 OTP/concurrency, 1 performance/infra)

---

## Phase 1: Critical Security & Stability (Weeks 1-3) - **P0 - DEPLOY IMMEDIATELY**

### 1.1 Authentication Security Overhaul

#### **Task 1.1.1: Fix Authentication Bypass**
**File**: `lib/mimo_web/plugs/authentication.ex`  
**Risk**: Critical - Remote anonymous access by default  
**Implementation**:

```elixir
defmodule MimoWeb.Plugs.Authentication do
  @moduledoc """
  API Key authentication with zero-tolerance security.
  NEVER allows unauthenticated requests in production.
  """
  
  @behaviour Plug
  
  def init(opts), do: opts

  def call(conn, _opts) do
    api_key = get_configured_key()
    
    # PRODUCTION SAFETY: Always require authentication
    if Mix.env() == :prod and (is_nil(api_key) or api_key == "") do
      Logger.error("SECURITY: No API key configured in production - blocking all requests")
      
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{
        error: "Service misconfigured",
        security: "API key required in production"
      }))
      |> halt()
    else
      case validate_bearer_token(conn) do
        {:ok, token} ->
          if secure_compare(token, api_key) do
            register_authenticated_conn(conn)
          else
            log_auth_failure(conn, :invalid_token)
            authentication_error(conn, :invalid_credentials)
          end
          
        {:error, :missing_header} ->
          log_auth_failure(conn, :missing_auth)
          authentication_error(conn, :missing_credentials)
          
        {:error, :invalid_format} ->
          log_auth_failure(conn, :malformed_auth)
          authentication_error(conn, :malformed_credentials)
      end
    end
  end
  
  # Constant-time comparison to prevent timing attacks
  defp secure_compare(nil, _), do: false
  defp secure_compare(_, nil), do: false
  defp secure_compare(token, api_key) when is_binary(token) and is_binary(api_key) do
    :crypto.mac_equals(token, api_key)
  end
  defp secure_compare(_, _), do: false
  
  # Always returns error response in production
  defp authentication_error(conn, reason) do
    status = if Mix.env() == :prod, do: 401, else: 401
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{
      error: "Authentication required",
      reason: reason,
      security_event_id: generate_event_id()
    }))
    |> halt()
  end
  
  # Telemetry logging of ALL auth events
  defp log_auth_failure(conn, reason) do
    :telemetry.execute([:mimo, :security, :auth_failure], %{
      client_ip: get_client_ip(conn),
      reason: reason,
      timestamp: System.system_time(:second)
    })
    
    Logger.warning("[SECURITY] Authentication failure from #{get_client_ip(conn)}: #{reason}")
  end
  
  defp get_configured_key, do: Application.get_env(:mimo_mcp, :api_key)
  defp get_client_ip(conn), do: to_string(:inet.ntoa(conn.remote_ip))
  defp generate_event_id, do: UUID.uuid4()
  defp register_authenticated_conn(conn), do: assign(conn, :authenticated, true)
end
```

**Acceptance Criteria**:
- [ ] All requests without valid API key return 401 in production
- [ ] No requests pass through without explicit authentication  
- [ ] Authentication failures emit telemetry events
- [ ] Timing attack prevention verified via benchmarking
- [ ] Integration tests cover all auth paths

**Estimate**: 8 hours

---

#### **Task 1.1.2: Implement API Key Management CLI**
**File**: `lib/mix/tasks/mimo_keys.ex` (new)  
**Purpose**: Secure key generation, rotation, and validation

```elixir
defmodule Mix.Tasks.Mimo.Keys.Generate do
  @moduledoc """
  Generates cryptographically secure API keys.
  
  ## Examples
  
      mix mimo.keys.generate --env prod --description "Production key for Claude Desktop"
      mix mimo.keys.generate --env dev --rotate --old-key OLD_KEY
  """
  
  use Mix.Task
  
  def run(args) do
    {opts, _} = OptionParser.parse!(args, 
      switches: [env: :string, description: :string, rotate: :boolean, old_key: :string]
    )
    
    Mix.Task.run("app.start")  # Ensure app config loaded
    
    new_key = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
    
    # Write to .env file with proper permissions
    env_file = ".env.#{opts[:env]}"
    File.write!(env_file, "MIMO_API_KEY=#{new_key}\n", [:append])
    File.chmod!(env_file, 0o600)  # Owner read/write only
    
    # Log to console (not file) for operator to copy
    Mix.shell().info("Generated API key: #{IO.ANSI.cyan()}#{new_key}#{IO.ANSI.reset()}")
    Mix.shell().info("Written to: #{env_file}")
    Mix.shell().info("⚠️  SAVE THIS KEY NOW - it will not be shown again")
    
    {:ok, new_key}
  end
end
```

**Acceptance Criteria**:
- [ ] Keys are 256-bit cryptographically random
- [ ] Files created with 0600 permissions (owner-only)
- [ ] Rotation workflow documented and tested
- [ ] No keys logged to disk or application logs

**Estimate**: 6 hours

---

### 1.2 Command Injection Prevention

#### **Task 1.2.1: Implement Secure Process Spawning**
**File**: `lib/mimo/skills/secure_executor.ex` (replaces `client.ex` vulnerable patterns)

```elixir
defmodule Mimo.Skills.SecureExecutor do
  @moduledoc """
  Secure subprocess execution with mandatory sandboxing.
  Prevents command injection and limits resource abuse.
  """
  
  @allowed_commands %{
    "npx" => %{
      min_version: "7.0.0",
      max_args: 10,
      timeout_ms: 60_000,
      max_memory_mb: 512
    },
    "docker" => %{
      min_version: "20.0.0",
      restriction: [:no_privileged, :no_host_network, :no_docker_sock],
      timeout_ms: 120_000
    }
  }
  
  def execute_skill(config) when is_map(config) do
    with {:ok, normalized} <- normalize_config(config),
         {:ok, validated} <- validate_config(normalized),
         {:ok, secure_opts} <- build_secure_opts(validated) do
      do_spawn(validated.command, validated.args, secure_opts)
    end
  end
  
  # Command normalization
  defp normalize_config(%{"command" => cmd} = config) do
    normalized_cmd = Path.basename(cmd)  # Prevent path traversal
    args = Map.get(config, "args", [])
    
    {:ok, %{
      command: normalized_cmd,
      args: Enum.map(args, &to_string/1),  # Force string conversion
      env: sanitize_env(Map.get(config, "env", %{}))
    }}
  end
  
  # Strict validation against whitelist
  defp validate_config(%{command: cmd} = config) do
    case Map.get(@allowed_commands, cmd) do
      nil ->
        {:error, {:command_not_allowed, cmd, Map.keys(@allowed_commands)}}
        
    restrictions -> 
        with :ok <- validate_args(cmd, config.args),
             :ok <- validate_env_interpolation(config.env) do
          {:ok, config}
        end
    end
  end
  
  # Argument validation prevents injection
  defp validate_args("npx", args) do
    cond do
      length(args) > 10 -> {:error, {:too_many_args, length(args), 10}}
      Enum.any?(args, &(&1 =~ ~r/[\r\n;&|`$()]/)) -> {:error, {:invalid_arg_characters}}
      true -> :ok
    end
  end
  
  # Environment variable sandboxing
  defp sanitize_env(env) do
    env
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_env_value(v)} end)
    |> Enum.filter(fn {_, v} -> v != :filtered end)
  end
  
  defp sanitize_env_value("${" <> _ = value) do
    # Only allow specific variable patterns
    case Regex.run(~r/\$\{([A-Z_][A-Z0-9_]*)\}/, value) do
      [_, var] when var in ~w(EXA_API_KEY GITHUB_TOKEN) -> value
      _ -> :filtered
    end
  end
  defp sanitize_env_value(value), do: value
  
  # Secure port spawning with resource limits
  defp do_spawn(cmd, args, opts) do
    executable = case System.find_executable(cmd) do
      nil -> raise "Command not found: #{cmd}"
      path -> path
    end
    
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:args, args},
      {:env, opts[:env]},
      {:line, 16384},
      {:parallelism, true}
    ]
    
    # Spawn with monitoring
    port = Port.open({:spawn_executable, executable}, port_opts)
    Process.monitor(port)
    
    case :erlang.port_info(port) do
      :undefined -> {:error, :port_spawn_failed}
      _ -> {:ok, port}
    end
  end
end
```

**Acceptance Criteria**:
- [ ] Only whitelisted commands can execute
- [ ] Command arguments sanitized (no shell metacharacters)
- [ ] Environment variables filtered to approved list
- [ ] Resource limits enforced (memory, CPU)
- [ ] All failures logged with security context

**Estimate**: 12 hours

---

#### **Task 1.2.2: Implement Skill Configuration Validator**
**File**: `lib/mimo/skills/validator.ex` (new)

```elixir
defmodule Mimo.Skills.Validator do
  @moduledoc """
  JSON Schema validation for skill configurations.
  Prevents injection via malformed configs.
  """
  
  @skill_schema %{
    "type" => "object",
    "required" => ["command"],
    "additionalProperties" => false,
    "properties" => %{
      "command" => %{
        "type" => "string",
        "enum" => ["npx", "docker"],  # Whitelist only
        "description" => "Command to execute"
      },
      "args" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "maxItems" => 10,
        "description" => "Command arguments"
      },
      "env" => %{
        "type" => "object",
        "patternProperties" => %{
          "^[A-Z_][A-Z0-9_]*$" => %{"type" => "string"}
        },
        "additionalProperties" => false,
        "maxProperties" => 20
      }
    }
  }
  
  def validate_config(config) when is_map(config) do
    # Convert string keys to atoms safely
    config = for {k, v} <- config, into: %{}, do: {to_string(k), v}
    
    with :ok <- validate_schema(config),
         :ok <- validate_env_interpolation(config) do
      {:ok, config}
    end
  end
  
  defp validate_schema(config) do
    case JsonXema.validate(@skill_schema, config) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_schema, errors}}
    end
  end
  
  # Prevents template injection
  defp validate_env_interpolation(%{"env" => env}) do
    env
    |> Enum.map(fn {_, v} -> validate_env_value(v) end)
    |> Enum.reduce(:ok, fn
      :ok, :ok -> :ok
      err, _ -> err
    end)
  end
  
  defp validate_env_value("${" <> rest) do
    case Regex.run(~r/\$\{([A-Z_][A-Z0-9_]*)\}$/, rest) do
      [_, var] when var in ~w(EXA_API_KEY GITHUB_TOKEN) -> :ok
      _ -> {:error, {:invalid_env_var, rest}}
    end
  end
  defp validate_env_value(_), do: :ok
end
```

**Acceptance Criteria**:
- [ ] All skill configs validated before execution
- [ ] Invalid configs rejected with clear error messages
- [ ] No environment variable injection possible
- [ ] Schema files version-controlled and tested

**Estimate**: 6 hours

---

### 1.3 Memory Safety & Resource Limits

#### **Task 1.3.1: Implement Memory Search with Streaming**
**File**: `lib/mimo/brain/memory.ex` (refactor)

```elixir
defmodule Mimo.Brain.Memory do
  @max_memory_batch_size 1000
  @default_embedding_dim 768
  
  @doc """
  Search memories with bounded memory usage using streaming.
  Guarantees O(1) memory regardless of database size.
  """
  def search_memories(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    
    with {:ok, query_embedding} <- generate_embedding(query),
         {:ok, results} <- stream_search(query_embedding, limit, min_similarity) do
      {:ok, results}
    end
  end
  
  # O(1) memory streaming implementation
  defp stream_search(query_embedding, limit, min_similarity) do
    # Use Ecto stream to avoid loading all records
    query = from(e in Engram, select: e)
    
    query
    |> Repo.stream(max_rows: @max_memory_batch_size)
    |> Stream.map(&calculate_similarity_wrapper(&1, query_embedding))
    |> Stream.filter(&(&1.similarity >= min_similarity))
    |> Stream.take(limit * 2)  # Take extra for sorting
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
    |> then(&{:ok, &1})
  rescue
    e ->
      Logger.error("Memory search failed: #{Exception.message(e)}")
      {:error, :search_failed}
  end
  
  # Wrapper ensures proper error handling per-record
  defp calculate_similarity_wrapper(engram, query_embedding) do
    %{
      id: engram.id,
      content: engram.content,
      category: engram.category,
      importance: engram.importance,
      similarity: calculate_similarity(query_embedding, engram.embedding)
    }
  end
  
  @doc """
  Store memory with validation and size limits.
  """
  def persist_memory(content, category, importance \\ 0.5) do
    with :ok <- validate_content_size(content),
         {:ok, embedding} <- generate_embedding(content),
         :ok <- validate_embedding_dimension(embedding),
         {:ok, engram} <- insert_memory(content, category, importance, embedding) do
      {:ok, engram.id}
    end
  end
  
  defp validate_content_size(content) when byte_size(content) > 100_000 do
    {:error, :content_too_large}
  end
  defp validate_content_size(_), do: :ok
  
  defp validate_embedding_dimension(embedding) when length(embedding) > @default_embedding_dim * 2 do
    {:error, :embedding_too_large}
  end
  defp validate_embedding_dimension(_), do: :ok
  
  defp insert_memory(content, category, importance, embedding) do
    changeset = Engram.changeset(%Engram{}, %{
      content: content,
      category: category,
      importance: importance,
      embedding: Jason.encode!(embedding),  # Store as JSONB for efficiency
      embedding_dim: length(embedding)
    })
    
    Repo.insert(changeset)
  end
  
  defp generate_embedding(text) do
    case Mimo.Brain.LLM.generate_embedding(text) do
      {:ok, embedding} -> {:ok, embedding}
      {:error, _} -> fallback_embedding(text)
    end
  end
end
```

**Acceptance Criteria**:
- [ ] Memory usage constant regardless of database size
- [ ] No full table scans under any circumstances
- [ ] Configurable batch size (default: 1,000)
- [ ] Content size limits enforced (100KB per memory)
- [ ] Embedding dimension validated

**Estimate**: 16 hours

---

#### **Task 1.3.2: Implement Memory Cleanup & TTL**
**File**: `lib/mimo/brain/cleanup.ex` (new)

```elixir
defmodule Mimo.Brain.Cleanup do
  use GenServer
  
  # Memory retention policies
  @default_ttl_days 30
  @low_importance_ttl_days 7
  @max_memory_count 100_000
  @cleanup_interval_ms 60 * 60 * 1000  # Hourly
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_) do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %{}}
  end
  
  @impl true
  def handle_info(:cleanup, state) do
    Logger.info("Starting memory cleanup...")
    
    cleanup_old_memories()
    cleanup_low_importance_memories()
    enforce_memory_limit()
    
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end
  
  # Remove memories older than TTL
  defp cleanup_old_memories do
    {count, _} = Repo.delete_all(
      from(e in Engram,
        where: e.inserted_at < ago(@default_ttl_days, "day"),
        where: e.importance < 0.7
      )
    )
    
    Logger.info("Cleaned up #{count} old memories")
  end
  
  # Remove low-importance memories if DB too large
  defp enforce_memory_limit do
    current_count = Repo.one(from e in Engram, select: count(e.id))
    
    if current_count > @max_memory_count do
      to_remove = current_count - @max_memory_count
      
      {count, _} = Repo.delete_all(
        from(e in Engram,
          where: e.importance < 0.5,
          order_by: [asc: e.inserted_at],
          limit: to_remove
        )
      )
      
      Logger.warning("Memory limit exceeded: removed #{count} low-importance memories")
    end
  end
  
  def force_cleanup do
    GenServer.cast(__MODULE__, :force_cleanup)
  end
end
```

**Acceptance Criteria**:
- [ ] Automatic hourly cleanup of old memories
- [ ] Hard limit on total memory count (100K default)
- [ ] Low-importance memories purged first
- [ ] Manual cleanup API for operators
- [ ] Cleanup events logged and telemetered

**Estimate**: 10 hours

---

## Phase 2: Race Condition Elimination (Weeks 4-7)

### 2.1 Registry & ETS Rewrite

#### **Task 2.1.1: Replace ETS with `:pg` for Distributed Coordination**
**File**: `lib/mimo/tool_registry.ex` (replaces registry.ex)

```elixir
defmodule Mimo.ToolRegistry do
  use GenServer
  
  @topic :"mimo_tools_#{Mix.env()}"
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_) do
    # Join distributed process group
    :pg.join(@topic, self())
    
    {:ok, %{
      tools: %{},  # tool_name => {skill_name, pid, metadata}
      skills: %{},  # skill_name => %{pid: pid, tools: [tool_names], health: :healthy}
      monitors: %{}  # pid => ref
    }}
  end
  
  # Atomic tool registration with automatic cleanup
  def register_skill_tools(skill_name, tools, pid) when is_list(tools) do
    GenServer.call(__MODULE__, {:register, skill_name, tools, pid}, 30_000)
  end
  
  # Atomic skill unregistration
  def unregister_skill(skill_name) do
    GenServer.cast(__MODULE__, {:unregister, skill_name})
  end
  
  # Thread-safe tool lookup
  def get_tool_owner(tool_name) do
    GenServer.call(__MODULE__, {:lookup, tool_name})
  end
  
  @impl true
  def handle_call({:register, skill_name, tools, pid}, _from, state) do
    # Monitor process for automatic cleanup
    ref = Process.monitor(pid)
    
    # Atomically update state
    new_tools = Map.new(tools, fn tool ->
      prefixed = "#{skill_name}_#{tool["name"]}"
      {prefixed, {skill_name, pid, tool}}
    end)
    
    new_state = %{
      state |
      tools: Map.merge(state.tools, new_tools),
      skills: Map.put(state.skills, skill_name, %{
        pid: pid,
        tools: Map.keys(new_tools),
        health: :healthy
      }),
      monitors: Map.put(state.monitors, pid, ref)
    }
    
    {:reply, {:ok, Map.keys(new_tools)}, new_state}
  end
  
  @impl true
  def handle_call({:lookup, tool_name}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil -> {:reply, {:error, :not_found}, state}
      {skill_name, pid, tool_def} ->
        case Process.alive?(pid) do
          true -> {:reply, {:ok, {:skill, skill_name, pid, tool_def}}, state}
          false ->
            # Automatic cleanup of dead process
            {:reply, {:error, :not_found}, cleanup_dead_skill(state, skill_name)}
        end
    end
  end
  
  # Handle process death automatically
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {skill_name, new_state} = find_skill_by_pid(state, pid)
    
    Logger.warning("Skill #{skill_name} died, cleaning up registry")
    
    {:noreply, cleanup_dead_skill(new_state, skill_name)}
  end
  
  defp cleanup_dead_skill(state, skill_name) do
    case Map.get(state.skills, skill_name) do
      nil -> state
      %{tools: tools} ->
        new_tools = Map.drop(state.tools, tools)
        new_skills = Map.delete(state.skills, skill_name)
        
        %{state | tools: new_tools, skills: new_skills}
    end
  end
end
```

**Acceptance Criteria**:
- [ ] Zero TOCTOU race conditions
- [ ] Automatic cleanup of dead processes
- [ ] Distributed process coordination via `:pg`
- [ ] Thread-safe atomic operations
- [ ] 100% test coverage for all registry paths

**Estimate**: 24 hours

---

#### **Task 2.1.2: Implement Distributed Lock for Hot Reload**
**File**: `lib/mimo/skills/hot_reload.ex` (new)

```elixir
defmodule Mimo.Skills.HotReload do
  @moduledoc """
  Atomic hot reload with distributed locking.
  Prevents registration loss during reload.
  """
  
  @lock_key :skill_reload_lock
  
  def reload_skills do
    # Acquire distributed lock
    case acquire_lock() do
      {:ok, lock_token} ->
        try do
          do_reload()
        after
          release_lock(lock_token)
        end
        
      {:error, :lock_taken} ->
        Logger.warning("Hot reload already in progress, skipping")
        {:error, :reload_in_progress}
    end
  end
  
  defp do_reload do
    Logger.warning("🔄 Hot reload starting...")
    
    # Signal all skills to drain
    Mimo.ToolRegistry.signal_drain()
    
    # Wait for in-flight requests to complete
    await_draining()
    
    # Now safely clear and reload
    Mimo.ToolRegistry.clear_all()
    Mimo.Skills.Catalog.reload()
    
    Logger.warning("✅ Hot reload complete")
    {:ok, :reloaded}
  end
  
  defp acquire_lock do
    # Use :global for distributed lock
    case :global.trans({@lock_key, self()}, fn -> :acquired end, 30_000) do
      :acquired -> {:ok, make_ref()}
      :aborted -> {:error, :lock_taken}
    end
  end
  
  defp release_lock(_token) do
    :global.del_lock({@lock_key, self()})
  end
  
  defp await_draining do
    # Wait max 30 seconds for draining
    Enum.reduce(1..30, false, fn 
      _, true -> true
      _, false ->
        if Mimo.ToolRegistry.all_drained?() do
          true
        else
          Process.sleep(1000)
          false
        end
    end)
  end
end
```

**Acceptance Criteria**:
- [ ] Hot reload atomic and lossless
- [ ] Concurrent reloads blocked
- [ ] In-flight requests complete before reload
- [ ] Zero skill registration loss
- [ ] Reload status observable via telemetry

**Estimate**: 12 hours

---

### 2.2 Memory Safety with Transactions

#### **Task 2.2.1: Wrap Memory Operations in Transactions**
**File**: `lib/mimo/brain/memory.ex` (refactor)

```elixir
defmodule Mimo.Brain.Memory do
  @doc """
  Store memory with ACID guarantees.
  """
  def persist_memory(content, category, importance \\ 0.5) do
    Repo.transaction(fn ->
      case generate_embedding(content) do
        {:ok, embedding} ->
          changeset = Engram.changeset(%Engram{}, %{
            content: content,
            category: category,
            importance: importance,
            embedding: embedding
          })
          
          case Repo.insert(changeset) do
            {:ok, engram} -> {:ok, engram.id}
            {:error, changeset} -> Repo.rollback(changeset.errors)
          end
          
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end
  
  @doc """
  Store multiple memories atomically.
  """
  def persist_memories(memories) when is_list(memories) do
    Repo.transaction(fn ->
      Enum.map(memories, fn memory ->
        case persist_memory(
          memory.content,
          memory.category,
          memory.importance
        ) do
          {:ok, id} -> id
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end
end
```

**Acceptance Criteria**:
- [ ] All memory operations ACID-compliant
- [ ] Concurrent writes don't corrupt data
- [ ] Rollback on embedding generation failure
- [ ] Transaction isolation verified in tests

**Estimate**: 8 hours

---

## Phase 3: Feature Implementation (Weeks 8-11)

### 3.1 Semantic Store Implementation

#### **Task 3.1.1: Implement Semantic Search & Graph Traversal**
**File**: `lib/mimo/semantic_store/search.ex` (new)

```elixir
defmodule Mimo.SemanticStore.Search do
  @moduledoc """
  Graph-based semantic search engine.
  Implements multi-hop traversal and pattern matching.
  """
  
  @doc """
  Search for entities matching graph patterns.
  
  Example:
      search_pattern([
        {:entity, "works_at", "company"},
        {:company, "located_in", "city"}
      ])
  """
  def search_pattern(patterns, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.8)
    
    query = build_pattern_query(patterns, min_confidence)
    
    Repo.all(query, limit: limit)
    |> Enum.map(&hydrate_entity/1)
  end
  
  defp build_pattern_query(patterns, min_confidence) do
    # Convert patterns to recursive CTE
    initial_query = build_initial_cte(patterns)
    
    recursive_query = build_recursive_cte(patterns)
    
    from(t in "semantic_triples",
      join: cte in "cte PatternMatch",
      on: t.subject_hash == cte.subject_hash,
      where: t.confidence >= ^min_confidence,
      order_by: [desc: t.confidence]
    )
  end
  
  defp build_initial_cte([{subject_type, predicate, object_type}]) do
    # Base case: single hop
    """
    WITH RECURSIVE PatternMatch AS (
      SELECT subject_hash, subject_id, 1 as depth
      FROM semantic_triples
      WHERE subject_type = '#{subject_type}'
        AND predicate = '#{predicate}'
        AND object_type = '#{object_type}'
    )
    """
  end
  
  defp build_recursive_cte(patterns) when length(patterns) > 1 do
    # Recursive case: multi-hop
    """
    UNION ALL
    SELECT t.subject_hash, t.subject_id, pm.depth + 1
    FROM semantic_triples t
    JOIN PatternMatch pm ON t.object_id = pm.subject_id
    WHERE t.confidence >= ?
      AND pm.depth < ?
    """
  end
  
  # Transform triples to entity structs
  defp hydrate_entity(triple) do
    %Mimo.SemanticStore.Entity{
      id: triple.object_id,
      type: triple.object_type,
      relationships: load_relationships(triple.object_id),
      confidence: triple.confidence
    }
  end
  
  defp load_relationships(entity_id) do
    from(t in Mimo.SemanticStore.Triple,
      where: t.subject_id == ^entity_id,
      select: {t.predicate, t.object_id}
    )
    |> Repo.all()
    |> Map.new()
  end
end
```

**Acceptance Criteria**:
- [ ] Multi-hop graph traversal working
- [ ] Pattern matching against relationship graphs
- [ ] Confidence-based filtering
- [ ] CTE queries optimized with indexes
- [ ] Integration tests for graph operations

**Estimate**: 32 hours

---

#### **Task 3.1.2: Connect Semantic Store to Query Interface**
**File**: `lib/mimo/ports/query_interface.ex` (refactor)

```elixir
defmodule Mimo.QueryInterface do
  @doc """
  Process query through Meta-Cognitive Router with real stores.
  """
  def ask(query, context_id \\ nil, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)
    
    Task.async(fn ->
      router_decision = Mimo.MetaCognitiveRouter.classify(query)
      
      # Spawn parallel searches based on router decision
      tasks = spawn_store_searches(query, router_decision)
      
      # Wait for results with timeout
      results = await_search_results(tasks, timeout_ms)
      
      # Synthesize across store results
      synthesis = synthesize_results(query, router_decision, results)
      
      %{
        query_id: UUID.uuid4(),
        router_decision: router_decision,
        results: results,
        synthesis: synthesis,
        context_id: context_id
      }
    end)
    |> Task.await(timeout_ms)
  end
  
  defp spawn_store_searches(query, decision) do
    tasks = %{}
    
    # Always search episodic
    tasks = Map.put(tasks, :episodic, 
      Task.async(fn -> Mimo.Brain.Memory.search_memories(query) end)
    )
    
    # Search semantic if primary or secondary
    if decision.primary_store == :semantic or :semantic in decision.secondary_stores do
      tasks = Map.put(tasks, :semantic,
        Task.async(fn -> Mimo.SemanticStore.Search.search_natural(query) end)
      )
    end
    
    # Search procedural if primary or secondary
    if decision.primary_store == :procedural or :procedural in decision.secondary_stores do
      tasks = Map.put(tasks, :procedural,
        Task.async(fn -> Mimo.ProceduralStore.Query.find_applicable(query) end)
      )
    end
    
    tasks
  end
  
  defp await_search_results(tasks, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    
    Enum.map(tasks, fn {store, task} ->
      remaining = max(0, deadline - System.monotonic_time(:millisecond))
      
      result = case Task.await(task, remaining) do
        {:ok, results} -> results
        {:error, _} -> []
        :timeout -> []
      end
      
      {store, result}
    end)
    |> Map.new()
  end
  
  defp synthesize_results(query, decision, results) do
    if decision.requires_synthesis do
      Mimo.Brain.LLM.consult_chief_of_staff(query, results)
    else
      nil
    end
  end
end
```

**Acceptance Criteria**:
- [ ] Semantic search integrated into query flow
- [ ] Router decision executed with real stores
- [ ] Parallel search execution for performance
- [ ] Synthesis combines results from multiple stores
- [ ] Integration tests validate complete flow

**Estimate**: 16 hours

---

### 3.2 Procedural Store Implementation

#### **Task 3.2.1: Implement State Machine Execution Engine**
**File**: `lib/mimo/procedural_store/executor.ex` (new)

```elixir
defmodule Mimo.ProceduralStore.Executor do
  @moduledoc """
  Deterministic state machine execution for procedures.
  Guarantees exact execution without LLM involvement.
  """
  
  @behaviour :gen_statem
  
  def start_procedure(name, version, context) when is_map(context) do
    case Mimo.ProceduralStore.Loader.get_procedure(name, version) do
      {:ok, procedure} ->
        :gen_statem.start(__MODULE__, {procedure, context}, [])
        
      {:error, :not_found} ->
        {:error, {:procedure_not_found, name, version}}
    end
  end
  
  @impl true
  def init({procedure, initial_context}) do
    data = %{
      procedure: procedure,
      context: initial_context,
      history: [],
      start_time: System.monotonic_time(:millisecond)
    }
    
    Logger.info("Starting procedure #{procedure.name}:#{procedure.version}")
    
    {:ok, procedure.initial_state, data}
  end
  
  @impl true
  def callback_mode, do: [:state_functions, :state_enter]
  
  # State entry actions
  def :enter(state, _prev_state, data) do
    case execute_state_action(state, data) do
      {:ok, result} ->
        new_data = update_context(data, result)
        next_state = determine_transition(state, result, data.procedure)
        
        {:next_state, next_state, new_data}
        
      {:error, error} ->
        Logger.error("Procedure #{data.procedure.name} state #{state} failed: #{inspect(error)}")
        {:stop, {:error, {state, error}}}
    end
  end
  
  # Execute state's action function
  defp execute_state_action(state, data) do
    state_def = Map.get(data.procedure.definition.states, state)
    
    case state_def do
      %{"action" => action_spec} ->
        module = String.to_atom(action_spec["module"])
        function = String.to_atom(action_spec["function"])
        
        apply(module, function, [data.context])
        
      _ ->
        {:ok, nil}  # No action, just transition
    end
  end
  
  # Update context with action results
  defp update_context(data, result) do
    new_context = Map.merge(data.context, %{result: result})
    
    %{data | 
      context: new_context,
      history: [{data.procedure.current_state, result} | data.history]
    }
  end
  
  # Determine next state based on transitions
  defp determine_transition(current_state, result, procedure) do
    state_def = procedure.definition.states[current_state]
    
    case find_matching_transition(result, state_def["transitions"]) do
      %{"target" => next_state} -> next_state
      nil -> :done
    end
  end
  
  defp find_matching_transition(result, transitions) when is_list(transitions) do
    Enum.find(transitions, fn t ->
      event = Map.get(t, "event", "success")
      event == result || event == "default"
    end)
  end
end
```

**Acceptance Criteria**:
- [ ] State machines execute deterministically
- [ ] Context passed between states correctly
- [ ] Rollback on error conditions
- [ ] Execution history logged for audit
- [ ] Timeout enforcement per state

**Estimate**: 40 hours

---

### 3.3 Rust NIF Implementation

#### **Task 3.3.1: Build and Ship Rust NIF Binaries**
**File**: `native/vector_math/build.sh` (new)

```bash
#!/bin/bash
# Build script for vector_math NIF

set -e

RUSTLER_NIF_VERSION="2.15"
TARGETS=("x86_64-unknown-linux-gnu" "aarch64-unknown-linux-gnu" "x86_64-apple-darwin")

# Install cross-compilation targets
for target in "${TARGETS[@]}"; do
  rustup target add "$target"
done

# Build for each target
for target in "${TARGETS[@]}"; do
  echo "Building for $target..."
  
  cargo build --release --target "$target"
  
  # Copy to priv/native/ with proper naming
  mkdir -p "priv/native/$target"
  cp "target/$target/release/libvector_math.so" "priv/native/$target/"
  
  # Strip symbols to reduce size
  strip "priv/native/$target/libvector_math.so"
done

# Generate checksums for integrity
sha256sum priv/native/*/libvector_math.so > priv/native/checksums.txt

# Create Elixir loader
elixir_load_code="
defmodule Mimo.Vector.NIFLoader do
  @nif_paths %{
    {:unix, :linux, :x86_64} => "priv/native/x86_64-unknown-linux-gnu/libvector_math.so",
    {:unix, :linux, :aarch64} => "priv/native/aarch64-unknown-linux-gnu/libvector_math.so",
    {:unix, :darwin, :x86_64} => "priv/native/x86_64-apple-darwin/libvector_math.so"
  }
  
  def load_nif do
    target = detect_target()
    path = Map.get(@nif_paths, target)
    
    if path && File.exists?(path) do
      :erlang.load_nif(String.to_charlist(path), 0)
    else
      Logger.warning("NIF not available for target #{inspect(target)}")
      {:error, :nif_not_available}
    end
  end
  
  defp detect_target do
    {os, arch} = :os.type()
    {os, arch, :erlang.system_info(:wordsize) * 8}
  end
end
"

echo "$elixir_load_code" > lib/mimo/vector/nif_loader.ex
```

**Acceptance Criteria**:
- [ ] Precompiled NIF binaries for Linux x86_64/aarch64 and macOS
- [ ] NIF loader detects platform automatically
- [ ] Checksums verify binary integrity
- [ ] Fallback to pure Elixir if NIF unavailable
- [ ] Performance tests show 10-40x speedup

**Estimate**: 24 hours

---

## Phase 4: Production Hardening (Weeks 12-16)

### 4.1 Monitoring & Observability

#### **Task 4.1.1: Implement Comprehensive Telemetry**
**File**: `lib/mimo/telemetry/instrumenter.ex` (new)

```elixir
defmodule Mimo.Telemetry.Instrumenter do
  use Supervisor
  
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end
  
  @impl true
  def init(_) do
    children = [
      # Custom telemetry handlers
      {TelemetryMetricsPrometheus, metrics: metrics()},
      {Mimo.Telemetry.HealthReporter, []}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  defp metrics do
    [
      # Latency distributions
      distribution("mimo.http.request.duration.milliseconds",
        buckets: [10, 50, 100, 500, 1000, 5000],
        tags: [:method, :path, :status]
      ),
      
      # Memory usage
      last_value("mimo.memory.episodic.store.bytes",
        unit: {:byte, :megabyte}
      ),
      
      # Semantic store graph metrics
      last_value("mimo.semantic_store.entities.total",
        tags: [:type]
      ),
      
      # Procedural store execution
      counter("mimo.procedural_store.execution.total",
        tags: [:procedure, :status]
      ),
      
      # Skill health
      last_value("mimo.skills.active.count"),
      last_value("mimo.skills.failed.count"),
      
      # Security events
      counter("mimo.security.auth.failure.total",
        tags: [:reason, :client_ip]
      )
    ]
  end
end
```

**Acceptance Criteria**:
- [ ] All critical paths instrumented
- [ ] Metrics exported in Prometheus format
- [ ] Grafana dashboards configured
- [ ] Alerting rules for anomalous behavior
- [ ] Health check endpoint returns detailed status

**Estimate**: 20 hours

---

### 4.2 Capacity Planning & Documentation

#### **Task 4.2.1: Create Production Deployment Guide**
**File**: `docs/deployment/production.md` (new)

**Content Outline**:
1. **Hardware Requirements**
   - CPU: 2 cores minimum, 4 cores recommended
   - RAM: 4GB minimum (10K memories), 16GB recommended (100K memories)
   - Disk: 10GB minimum, 100GB recommended (with retention)
   - Network: 1 Gbps internal, TLS termination at LB

2. **Docker Configuration**
   ```yaml
   services:
     mimo:
       image: mimo-mcp:3.0
       deploy:
         replicas: 3
         resources:
           limits:
             cpus: '2'
             memory: 8G
           reservations:
             cpus: '1'
             memory: 4G
       environment:
         MIMO_API_KEY: ${MIMO_API_KEY}
         DATABASE_POOL_SIZE: 20
   ```

3. **Scaling Guidelines**
   - **Horizontal**: Stateless HTTP layer scales linearly
   - **Vertical**: Memory store requires more RAM per 100K memories
   - **Ollama**: Deploy embedding service separately

4. **High Availability**
   - PostgreSQL instead of SQLite for multi-node
   - Redis for distributed locking
   - Load balancer health checks

**Acceptance Criteria**:
- [ ] Complete production checklist
- [ ] Sample configs for Docker/K8s
- [ ] Scaling formulas documented
- [ ] Troubleshooting guide included
- [ ] Security best practices section

**Estimate**: 16 hours

---

## Summary Timeline

| Phase | Weeks | Effort (hours) | Deliverables |
|-------|-------|----------------|--------------|
| 1: Security & Stability | 1-3 | 90 | Secure auth, command injection prevention, memory safety |
| 2: Race Conditions | 4-7 | 80 | Thread-safe registry, atomic hot reload, transactions |
| 3: Feature Implementation | 8-11 | 120 | Semantic Store, Procedural Store, Rust NIFs |
| 4: Production Hardening | 12-16 | 60 | Monitoring, docs, capacity planning |
| **Total** | **12-16** | **~350** | **Production-ready v3.0** |

---

## Success Metrics

**Security**:
- Zero authentication bypasses
- All subprocesses sandboxed
- Security audit scores 95+

**Performance**:
- Memory search: <100ms for 100K memories
- Vector operations: 10-40x speedup with NIFs
- HTTP latency: p99 <50ms

**Reliability**:
- Zero race conditions (verified via stress tests)
- 99.9% uptime in production
- Hot reload: zero downtime

**Features**:
- Semantic Store: full graph traversal
- Procedural Store: deterministic execution
- All advertised features functional

---

## Immediate Next Actions (This Week)

1. **Disable productions systems** until Phase 1 complete
2. **Implement authentication fix** (Task 1.1.1) - 1 day
3. **Deploy secure process spawning** (Task 1.2.1) - 1 day
4. **Add memory streaming** (Task 1.3.1) - 2 days
5. **Begin registry rewrite** (Task 2.1.1) - 3 days

**Commit to v3.0 release in 16 weeks with all issues resolved.**
