defmodule Mimo.Application do
  @moduledoc """
  OTP Application entry point.
  Uses lazy-loading: tools advertised from catalog, processes spawn on-demand.

  Universal Aperture Architecture:
  - MCP Server (stdio) for GitHub Copilot compatibility
  - Phoenix HTTP endpoint for REST/OpenAI API access
  - WebSocket Synapse for real-time cognitive signaling
  - Both adapters talk to the same Core via Port interfaces

  Synthetic Cortex Modules (Phase 2 & 3):
  - Semantic Store: Triple-based knowledge graph
  - Procedural Store: Deterministic state machine execution
  - Rust NIFs: SIMD-accelerated vector operations
  - WebSocket Synapse: Real-time bidirectional communication
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start Repo first
        Mimo.Repo,
        # Elixir Registry for via_tuple skill lookups
        {Registry, keys: :unique, name: Mimo.Skills.Registry},
        # Circuit breaker registry for error handling
        {Registry, keys: :unique, name: Mimo.CircuitBreaker.Registry},
        # Circuit breakers for external services (must start after Registry)
        # Use explicit IDs to avoid duplicate_child_name errors
        Supervisor.child_spec(
          {Mimo.ErrorHandling.CircuitBreaker, name: :llm_service, failure_threshold: 5},
          id: :circuit_breaker_llm_service
        ),
        Supervisor.child_spec(
          {Mimo.ErrorHandling.CircuitBreaker, name: :ollama, failure_threshold: 3},
          id: :circuit_breaker_ollama
        ),
        # Thread-safe tool registry with distributed coordination
        {Mimo.ToolRegistry, []},
        # Static tool catalog for lazy-loading (reads manifest)
        Mimo.Skills.Catalog,
        # Task supervisor for async operations
        {Task.Supervisor, name: Mimo.TaskSupervisor},
        # Dynamic supervisor for lazy-spawned skills
        {Mimo.Skills.Supervisor, []},
        # Hot reload manager for atomic skill reloading
        {Mimo.Skills.HotReload, []},
        # Classifier cache for LLM embedding/classification results
        {Mimo.Cache.Classifier, []},
        # Memory cleanup service with TTL management
        {Mimo.Brain.Cleanup, []},
        # Telemetry supervisor for metrics
        Mimo.Telemetry,
        # Resource monitor for operational visibility
        {Mimo.Telemetry.ResourceMonitor, []},
        # Semantic Store: Background inference ("The Dreamer")
        {Mimo.SemanticStore.Dreamer, []},
        # Semantic Store: Proactive context ("The Observer")
        {Mimo.SemanticStore.Observer, []},
        # ===== Cognitive Memory System (SPEC-001 to SPEC-005) =====
        # Working Memory: ETS-backed short-term storage with TTL
        {Mimo.Brain.WorkingMemory, []},
        # Working Memory Cleaner: Periodic TTL expiration
        {Mimo.Brain.WorkingMemoryCleaner, []},
        # Access Tracker: Async batched access tracking for decay scoring
        {Mimo.Brain.AccessTracker, []},
        # Consolidator: Working memory → Long-term memory transfer
        {Mimo.Brain.Consolidator, []},
        # Forgetting: Scheduled decay-based memory cleanup
        {Mimo.Brain.Forgetting, []}
      ] ++ synthetic_cortex_children()

    opts = [strategy: :one_for_one, name: Mimo.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    # Ensure catalog is fully loaded before servers start
    case wait_for_catalog_ready() do
      :ok ->
        # Start HTTP endpoint (Universal Aperture)
        start_http_endpoint(sup)

        # Start MCP server (stdio for GitHub Copilot)
        start_mcp_server(sup)

        Logger.info("Mimo-MCP Gateway v2.3.3 started (Universal Aperture mode)")
        Logger.info("  HTTP API: http://localhost:#{http_port()}")
        Logger.info("  MCP Server: stdio (port #{mcp_port()})")

      {:error, :catalog_timeout} ->
        Logger.warning("⚠️ Catalog not ready, starting servers with internal tools only")
        # Still start servers but with degraded functionality
        start_http_endpoint(sup)
        start_mcp_server(sup)

        Logger.warning("Mimo-MCP Gateway v2.3.3 started (degraded mode - catalog not loaded)")
    end

    {:ok, sup}
  end

  defp start_http_endpoint(sup) do
    # Skip HTTP in stdio mode (MIMO_DISABLE_HTTP=true)
    if System.get_env("MIMO_DISABLE_HTTP") == "true" do
      Logger.info("HTTP Gateway disabled (stdio mode)")
      :ok
    else
      child_spec = {MimoWeb.Endpoint, []}

      case Supervisor.start_child(sup, child_spec) do
        {:ok, _pid} ->
          Logger.info("✅ HTTP Gateway started on port #{http_port()}")

        {:error, reason} ->
          Logger.warning("⚠️ HTTP Gateway failed to start: #{inspect(reason)}")
      end
    end
  end

  defp start_mcp_server(sup) do
    port = mcp_port()

    child_spec = %{
      id: Mimo.McpServer,
      start: {Mimo.McpServer, :start_link, [[port: port]]},
      restart: :permanent
    }

    case Supervisor.start_child(sup, child_spec) do
      {:ok, _pid} ->
        Logger.info("✅ MCP Server started")

      {:error, reason} ->
        Logger.error("❌ MCP Server failed to start: #{inspect(reason)}")
    end
  end

  # Block until catalog has loaded tools from manifest
  defp wait_for_catalog_ready do
    # Quick check - if no external skills configured, don't wait
    try do
      tools = Mimo.Skills.Catalog.list_tools()

      if tools == [] do
        # Empty catalog is valid when no external skills are configured
        Logger.info("✅ Catalog ready (no external skills configured)")
        :ok
      else
        Logger.info("✅ Catalog ready with #{length(tools)} external tools")
        :ok
      end
    rescue
      e ->
        Logger.warning("Catalog check failed: #{Exception.message(e)}, starting without catalog")
        {:error, :catalog_timeout}
    end
  end

  defp http_port do
    Application.get_env(:mimo_mcp, MimoWeb.Endpoint)[:http][:port] || 4000
  end

  defp mcp_port do
    Application.fetch_env!(:mimo_mcp, :mcp_port)
  end

  # ============================================================================
  # Synthetic Cortex Module Management
  # ============================================================================

  # Returns children for enabled Synthetic Cortex modules.
  # Modules are enabled via feature flags in config:
  # - :rust_nifs - SIMD-accelerated vector operations
  # - :websocket_synapse - Real-time cognitive signaling
  # - :procedural_store - Deterministic state machine execution
  defp synthetic_cortex_children do
    []
    |> maybe_add_child(:rust_nifs, {Mimo.Vector.Supervisor, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.ConnectionManager, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.InterruptManager, []})
    |> maybe_add_child(:procedural_store, {Mimo.ProceduralStore.Registry, []})
  end

  defp maybe_add_child(children, feature, child_spec) do
    if feature_enabled?(feature) do
      [child_spec | children]
    else
      children
    end
  end

  @doc """
  Checks if a feature flag is enabled.

  Feature flags can be set via:
  - Config: `config :mimo_mcp, :feature_flags, semantic_store: true`
  - Environment: `SEMANTIC_STORE_ENABLED=true`
  """
  def feature_enabled?(feature) do
    flags = Application.get_env(:mimo_mcp, :feature_flags, [])

    case Keyword.get(flags, feature) do
      {:system, env_var, default} ->
        case System.get_env(env_var) do
          nil -> default
          "true" -> true
          "1" -> true
          _ -> false
        end

      true ->
        true

      false ->
        false

      nil ->
        false
    end
  end

  @doc """
  Returns status of all Synthetic Cortex modules.
  """
  def cortex_status do
    %{
      rust_nifs: %{
        enabled: feature_enabled?(:rust_nifs),
        loaded: rust_nif_loaded?()
      },
      semantic_store: %{
        enabled: feature_enabled?(:semantic_store),
        tables_exist: semantic_tables_exist?()
      },
      procedural_store: %{
        enabled: feature_enabled?(:procedural_store),
        tables_exist: procedural_tables_exist?()
      },
      websocket_synapse: %{
        enabled: feature_enabled?(:websocket_synapse),
        connections: websocket_connection_count()
      }
    }
  end

  defp rust_nif_loaded? do
    try do
      Mimo.Vector.Math.nif_loaded?()
    rescue
      _ -> false
    end
  end

  defp semantic_tables_exist? do
    try do
      Mimo.Repo.query("SELECT 1 FROM semantic_triples LIMIT 1")
      true
    rescue
      _ -> false
    end
  end

  defp procedural_tables_exist? do
    try do
      Mimo.Repo.query("SELECT 1 FROM procedural_registry LIMIT 1")
      true
    rescue
      _ -> false
    end
  end

  defp websocket_connection_count do
    if feature_enabled?(:websocket_synapse) do
      try do
        Mimo.Synapse.ConnectionManager.count()
      rescue
        _ -> 0
      end
    else
      0
    end
  end
end
