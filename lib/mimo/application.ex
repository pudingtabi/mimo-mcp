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
    # ===== LLM CONFIGURATION CHECK =====
    # Mimo requires LLM services to function. Check early and fail clearly.
    check_llm_configuration()

    children =
      [
        # Start Repo
        Mimo.Repo,
        # Elixir Registry for via_tuple skill lookups
        {Registry, keys: :unique, name: Mimo.Skills.Registry},
        # Circuit breaker registry for error handling
        {Registry, keys: :unique, name: Mimo.CircuitBreaker.Registry},
        # PG starter - ensures :pg process group is available for ToolRegistry
        %{
          id: :pg_starter,
          start: {__MODULE__, :start_pg, []},
          type: :worker
        },
        # Phoenix PubSub (required for WebSocket Synapse + Channels)
        {Phoenix.PubSub, name: Mimo.PubSub},
        # ===== GRACEFUL DEGRADATION FRAMEWORK (TASK 5 - Dec 6 2025) =====
        # ServiceRegistry: Tracks service initialization status and dependencies
        # Must start before other services so they can register
        {Mimo.Fallback.ServiceRegistry, []},
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
        # Circuit breaker for external web requests (Phase 1 Stability - Task 1.4)
        Supervisor.child_spec(
          {Mimo.ErrorHandling.CircuitBreaker, name: :web_service, failure_threshold: 10},
          id: :circuit_breaker_web
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
        # SPEC-061: Embedding cache for production performance
        {Mimo.Cache.Embedding, []},
        # SPEC-073: Search result cache for fast repeated queries
        {Mimo.Cache.SearchResult, []},
        # SPEC-064: File read LRU cache for token optimization
        {Mimo.Skills.FileReadCache, []},
        # SPEC-061: Telemetry profiler for bottleneck identification
        {Mimo.Telemetry.Profiler, []},
        # Memory cleanup service with TTL management
        {Mimo.Brain.Cleanup, []},
        # ===== System Health Monitoring (Q1 2026 Phase 1) =====
        # SystemHealth: Tracks memory corpus size, query latency, ETS usage
        # Provides early warning before performance degradation
        {Mimo.SystemHealth, []},
        # ===== ETS Crash Recovery (SPEC-045) =====
        # EtsHeirManager: Must start FIRST - acts as heir for ETS tables
        # When a GenServer crashes, its ETS table transfers here, not destroyed
        {Mimo.EtsHeirManager, []},
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
        # Activity Tracker: Tracks active usage days for pause-aware decay
        {Mimo.Brain.ActivityTracker, []},
        # Consolidator: Working memory → Long-term memory transfer
        {Mimo.Brain.Consolidator, []},
        # Forgetting: Scheduled decay-based memory cleanup
        {Mimo.Brain.Forgetting, []},
        # HealthMonitor: Periodic brain system health checks
        {Mimo.Brain.HealthMonitor, []},
        # ===== Passive Memory System (SPEC-012) =====
        # Thread Manager: AI session tracking and interaction recording
        {Mimo.Brain.ThreadManager, []},
        # Interaction Consolidator: Periodic consolidation of interactions → engrams via LLM curation
        {Mimo.Brain.InteractionConsolidator, []},
        # ===== Autonomous Synthesis (Intelligence Enhancement) =====
        # Synthesizer: Clusters memories and generates synthesis facts autonomously
        {Mimo.Brain.Synthesizer, []},
        # UsageFeedback: Tracks memory retrieval and learns which memories are useful
        {Mimo.Brain.UsageFeedback, []},
        # InferenceScheduler: Smart LLM orchestration with priority queue and batching
        {Mimo.Brain.InferenceScheduler, []},
        # ===== Living Codebase System (SPEC-021) =====
        # File watcher for real-time code indexing
        {Mimo.Code.FileWatcher, []},
        # ===== Cognitive Codebase Integration (SPEC-025) =====
        # Synapse Orchestrator - coordinates graph updates from code/memory changes
        {Mimo.Synapse.Orchestrator, []},
        # Graph Cache - ETS-backed caching layer for batch SQLite operations (Discord pattern)
        {Mimo.Synapse.GraphCache, []},
        # ===== Universal Library System (SPEC-022) =====
        # Cache manager for package documentation
        {Mimo.Library.CacheManager, []},
        # ===== Cognitive Mechanisms System (SPEC-024) =====
        # Uncertainty tracker for meta-learning
        {Mimo.Cognitive.UncertaintyTracker, []},
        # ===== AUTO-REASONING Adoption Metrics =====
        # Tracks when cognitive assess is used as first tool (Dec 6 2025)
        {Mimo.AdoptionMetrics, []},
        # ===== AI Intelligence Test (SPEC-AI-TEST) =====
        # Verification tracker for ceremonial vs genuine verification detection
        {Mimo.Brain.VerificationTracker, []},
        # ===== Unified Reasoning Engine (SPEC-035) =====
        # ReasoningSession: ETS-backed session storage for multi-step reasoning
        {Mimo.Cognitive.ReasoningSession, []},
        # ===== Awakening Protocol (SPEC-040) =====
        # SessionTracker: Tracks AI sessions and triggers awakening injection
        {Mimo.Awakening.SessionTracker, []},
        # ===== Emergent Capabilities Framework (SPEC-044) =====
        # Emergence Catalog: ETS-backed catalog for promoted patterns (MUST start before Scheduler)
        {Mimo.Brain.Emergence.Catalog, []},
        # Emergence Scheduler: Periodic pattern detection and promotion
        {Mimo.Brain.Emergence.Scheduler, []},
        # ===== Cognitive Feedback Loop (SPEC-074) =====
        # Core learning infrastructure - connects outcomes to behavior changes
        # NOTE: Must start BEFORE ActiveInference which depends on it
        {Mimo.Cognitive.FeedbackLoop, []},
        # ===== Active Inference (SPEC-071) =====
        # Proactive context pushing based on Free Energy Principle
        {Mimo.ActiveInference, []},
        # ===== Sleep Cycle (SPEC-072) =====
        # Multi-stage memory consolidation (episodic → semantic → procedural)
        {Mimo.SleepCycle, []},
        # Emergence Usage Tracker: Pattern usage and impact tracking (Q1 2026 Phase 2)
        {Mimo.Brain.Emergence.UsageTracker, []},
        # ===== Context Window Management (Phase 2 Cognitive Enhancement) =====
        # ContextWindowManager: Tracks token usage per session, warns on limits
        {Mimo.Context.ContextWindowManager, []},
        # ===== Predictive Context Preparation (Phase 3 Emergent Capabilities) =====
        # AccessPatternTracker: Tracks tool access patterns for prediction
        {Mimo.Context.AccessPatternTracker, []},
        # Prefetcher: Pre-fetches predicted context in background
        {Mimo.Context.Prefetcher, []},
        # ===== Cognitive Lifecycle Pattern (SPEC-042) =====
        # CognitiveLifecycle: Tracks phase transitions (context → deliberate → action → learn)
        {Mimo.Brain.CognitiveLifecycle, []},
        # ===== Evaluator-Optimizer Pattern (Phase 2 Cognitive Enhancement) =====
        # Optimizer: Self-improving evaluation with outcome tracking and feedback loop
        {Mimo.Brain.Reflector.Optimizer, []},
        # ===== Self-Improving Prompt Optimization (Phase 3 Emergent Capabilities) =====
        # PromptOptimizer: Learns from prompt effectiveness to improve suggestions
        {Mimo.Cognitive.PromptOptimizer, []},
        # ===== Knowledge Auto-Learning System =====
        # KnowledgeSyncer: Periodic memory → knowledge graph synchronization
        {Mimo.Brain.KnowledgeSyncer, []},
        # ===== Autonomous Task Execution (SPEC-071) =====
        # TaskRunner: Autonomous task queue with cognitive enhancement
        {Mimo.Autonomous.TaskRunner, []},
        # Onboard Tracker: Manages async onboarding state
        {Mimo.Tools.Dispatchers.Onboard.Tracker, []}
      ] ++ synthetic_cortex_children()

    opts = [strategy: :one_for_one, name: Mimo.Supervisor]

    # Gracefully handle supervisor start - allow partial degradation
    case Supervisor.start_link(children, opts) do
      {:ok, sup} ->
        # Successfully started supervisor
        start_post_init_tasks(sup)
        {:ok, sup}

      {:error, {:shutdown, {:failed_to_start_child, child_name, reason}}} ->
        Logger.error("""
        \u274C Failed to start critical child process: #{inspect(child_name)}
        Reason: #{inspect(reason)}

        This may be due to:
        - Missing dependencies (e.g., Ollama not running, HNSW NIF not compiled)
        - Database connection issues
        - Port conflicts

        Attempting graceful degradation...
        """)

        # Try to start with minimal children for degraded mode
        start_minimal_supervisor()

      {:error, reason} ->
        Logger.error("""
        \u274C Failed to start Mimo supervisor
        Reason: #{inspect(reason)}
        """)

        {:error, reason}
    end
  end

  defp start_post_init_tasks(sup) do
    # Start the graceful degradation retry processor (after TaskSupervisor is available)
    spawn(fn ->
      # Wait for TaskSupervisor to be ready
      Process.sleep(1000)
      Mimo.Fallback.GracefulDegradation.start_retry_processor()
    end)

    # Ensure catalog is fully loaded before servers start
    case wait_for_catalog_ready() do
      :ok ->
        # Start HTTP endpoint (Universal Aperture)
        start_http_endpoint(sup)

        # Start MCP server (stdio for GitHub Copilot)
        start_mcp_server(sup)

        Logger.info("Mimo-MCP Gateway v2.4.0 started (Universal Aperture mode)")
        Logger.info("  HTTP API: http://localhost:#{http_port()}")
        Logger.info("  MCP Server: stdio (port #{mcp_port()})")

      {:error, :catalog_timeout} ->
        Logger.warning("⚠️ Catalog not ready, starting servers with internal tools only")
        # Still start servers but with degraded functionality
        start_http_endpoint(sup)
        start_mcp_server(sup)

        Logger.warning("Mimo-MCP Gateway v2.4.0 started (degraded mode - catalog not loaded)")
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

  # LLM Configuration Check - Mimo requires LLM to function
  defp check_llm_configuration do
    alias Mimo.Brain.LLM

    case LLM.check_configuration() do
      {:ok, :fully_configured} ->
        Logger.info("✅ LLM services configured (LLM + Ollama)")
        :ok

      {:ok, :partial_no_embeddings} ->
        Logger.warning("""
        ⚠️ LLM configured but Ollama not available.
        Embeddings will not be generated. Memory search may be degraded.

        To fix: Start Ollama with 'ollama serve' or configure OLLAMA_URL in .env
        """)

        :ok

      {:ok, :partial_no_llm} ->
        Logger.warning("""
        ⚠️ Ollama available but no LLM API keys configured.
        AI reasoning features will not work.

        To fix: Add CEREBRAS_API_KEY or OPENROUTER_API_KEY to .env
        """)

        :ok

      {:error, :not_configured} ->
        error_message = """

        ═══════════════════════════════════════════════════════════════════════════════
        ❌ LLM NOT CONFIGURED
        ═══════════════════════════════════════════════════════════════════════════════

        Mimo requires LLM services to function. Please configure before using Mimo.

        REQUIRED - At least ONE of:
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ CEREBRAS_API_KEY=your_key    # Get free at https://cerebras.ai             │
        │ OPENROUTER_API_KEY=your_key  # Get free at https://openrouter.ai           │
        └─────────────────────────────────────────────────────────────────────────────┘

        RECOMMENDED - For embeddings:
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ Run: ollama serve                                                           │
        │ Or set: OLLAMA_URL=http://your-ollama-host:11434                           │
        └─────────────────────────────────────────────────────────────────────────────┘

        Add these to your .env file in the mimo-mcp directory and restart.

        ═══════════════════════════════════════════════════════════════════════════════
        """

        Logger.error(error_message)

        # In test mode, don't halt
        if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
          Logger.warning("Continuing in test mode (skip_external_apis=true)")
          :ok
        else
          # Print to stderr for MCP clients
          IO.puts(:stderr, error_message)
          # Don't crash, allow degraded startup
          :ok
        end
    end
  end

  # Minimal supervisor for degraded mode when full startup fails
  defp start_minimal_supervisor do
    Logger.warning("\u26A0\uFE0F Starting in minimal/degraded mode...")

    # Only essential children needed for basic operation
    minimal_children = [
      # Process groups for distributed coordination (required by ToolRegistry)
      %{id: :pg, start: {:pg, :start_link, []}},
      Mimo.Repo,
      {Registry, keys: :unique, name: Mimo.Skills.Registry},
      # Circuit breaker registry - needed for network/LLM calls
      {Registry, keys: :unique, name: Mimo.CircuitBreaker.Registry},
      # Essential circuit breakers for degraded mode
      Supervisor.child_spec(
        {Mimo.ErrorHandling.CircuitBreaker, name: :llm_service, failure_threshold: 5},
        id: :circuit_breaker_llm_service
      ),
      Supervisor.child_spec(
        {Mimo.ErrorHandling.CircuitBreaker, name: :ollama, failure_threshold: 3},
        id: :circuit_breaker_ollama
      ),
      Supervisor.child_spec(
        {Mimo.ErrorHandling.CircuitBreaker, name: :web_service, failure_threshold: 10},
        id: :circuit_breaker_web
      ),
      {Mimo.ToolRegistry, []},
      {Task.Supervisor, name: Mimo.TaskSupervisor},
      # Context window tracking (lightweight, useful even in degraded mode)
      {Mimo.Context.ContextWindowManager, []}
    ]

    opts = [strategy: :one_for_one, name: Mimo.Supervisor.Minimal]

    case Supervisor.start_link(minimal_children, opts) do
      {:ok, sup} ->
        Logger.info("\u2705 Minimal supervisor started successfully")

        # Try to start MCP server at least
        start_mcp_server(sup)

        Logger.warning("Mimo-MCP Gateway v2.4.0 started (MINIMAL/DEGRADED MODE)")
        Logger.warning("  Some features may not be available")

        {:ok, sup}

      {:error, reason} ->
        Logger.error("\u274C Even minimal supervisor failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Synthetic Cortex Module Management
  # ============================================================================

  # Returns children for enabled Synthetic Cortex modules.
  # Modules are enabled via feature flags in config:
  # - :rust_nifs - SIMD-accelerated vector operations
  # - :websocket_synapse - Real-time cognitive signaling
  # - :procedural_store - Deterministic state machine execution
  # - :hnsw_index - SPEC-033 HNSW vector index for O(log n) search
  defp synthetic_cortex_children do
    []
    |> maybe_add_child(:rust_nifs, {Mimo.Vector.Supervisor, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.ConnectionManager, []})
    |> maybe_add_child(:websocket_synapse, {Mimo.Synapse.InterruptManager, []})
    |> maybe_add_child(:procedural_store, {Mimo.ProceduralStore.Registry, []})
    |> maybe_add_child(:hnsw_index, {Mimo.Brain.HnswIndex, []})
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
      },
      hnsw_index: %{
        enabled: feature_enabled?(:hnsw_index),
        status: hnsw_index_status()
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

  defp hnsw_index_status do
    if feature_enabled?(:hnsw_index) do
      try do
        Mimo.Brain.HnswIndex.stats()
      rescue
        _ -> %{available: false, error: "not_running"}
      end
    else
      %{available: false, reason: :disabled}
    end
  end

  @doc """
  Start :pg process group server (called as part of supervision tree).
  """
  def start_pg do
    case :pg.start_link() do
      {:ok, pid} ->
        Logger.info("Started :pg process group server")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug(":pg already started")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start :pg: #{inspect(reason)}")
        error
    end
  end
end
