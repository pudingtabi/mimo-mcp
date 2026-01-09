import Config

# CRITICAL: Send logs to stderr so stdout remains clean for MCP JSON-RPC
# Also respect LOGGER_LEVEL env var for stdio mode
log_level =
  case System.get_env("LOGGER_LEVEL") do
    "error" -> :error
    "warn" -> :warning
    "none" -> :none
    _ -> :info
  end

config :logger, level: log_level

config :logger, :console,
  device: :standard_error,
  format: "$time $metadata[$level] $message\n"

# =============================================================================
# Database Configuration (SPEC-061: Connection Pooling)
# =============================================================================

if config_env() == :prod do
  config :mimo_mcp, Mimo.Repo,
    database: System.get_env("MIMO_DB_PATH") || "priv/mimo_mcp.db",
    # SPEC-061: Increased pool size for concurrent load
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    # Queue management for high concurrency
    queue_target: 50,
    queue_interval: 1000,
    # SQLite concurrency settings to prevent "Database busy" errors
    busy_timeout: 60_000,
    journal_mode: :wal,
    cache_size: -64_000,
    temp_store: :memory,
    mode: :readwrite,
    show_sensitive_data_on_connection_error: true
end

# Development/test pool settings
# SPEC-STABILITY: SQLite only allows ONE writer at a time.
# pool_size > 1 causes "Database busy" errors even with WriteSerializer.
if config_env() in [:dev, :test] do
  config :mimo_mcp, Mimo.Repo,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1"),
    queue_target: 50,
    queue_interval: 1000
end

# =============================================================================
# Universal Aperture: HTTP Gateway Configuration
# =============================================================================

# HTTP Server (Phoenix/Bandit)
http_port = String.to_integer(System.get_env("MIMO_HTTP_PORT") || "4000")

config :mimo_mcp, MimoWeb.Endpoint,
  http: [
    # Bind all interfaces (Docker will handle network isolation)
    ip: {0, 0, 0, 0},
    port: http_port,
    transport_options: [socket_opts: [:inet]]
  ],
  url: [host: System.get_env("MIMO_HOST") || "localhost", port: http_port],
  secret_key_base:
    System.get_env("MIMO_SECRET_KEY_BASE") ||
      Base.encode64(:crypto.strong_rand_bytes(48)),
  server: true,
  render_errors: [formats: [json: MimoWeb.ErrorJSON]]

# Runtime environment (cannot use Mix.env() in releases)
config :mimo_mcp, :environment, config_env()

# API Authentication
config :mimo_mcp, :api_key, System.get_env("MIMO_API_KEY")

# =============================================================================
# External Services Configuration
# =============================================================================

# Ollama (local embeddings) - SPEC-061: Connection pool settings
config :mimo_mcp, :ollama_url, System.get_env("OLLAMA_URL") || "http://localhost:11434"
config :mimo_mcp, :ollama_pool_size, String.to_integer(System.get_env("OLLAMA_POOL_SIZE") || "5")

config :mimo_mcp,
       :ollama_pool_overflow,
       String.to_integer(System.get_env("OLLAMA_POOL_OVERFLOW") || "2")

config :mimo_mcp, :ollama_timeout, String.to_integer(System.get_env("OLLAMA_TIMEOUT") || "30000")

# Cerebras (PRIMARY - ultra-fast inference, 3000+ tok/s)
config :mimo_mcp, :cerebras_api_key, System.get_env("CEREBRAS_API_KEY")
config :mimo_mcp, :cerebras_model, System.get_env("CEREBRAS_MODEL", "gpt-oss-120b")

config :mimo_mcp,
       :cerebras_fallback_model,
       System.get_env("CEREBRAS_FALLBACK_MODEL", "llama-3.3-70b")

# OpenRouter (fallback + vision)
config :mimo_mcp, :openrouter_api_key, System.get_env("OPENROUTER_API_KEY")

# Skills
config :mimo_mcp, :skills_path, System.get_env("SKILLS_PATH") || "priv/skills.json"

# MCP Server (stdio)
config :mimo_mcp, :mcp_port, String.to_integer(System.get_env("MCP_PORT") || "9000")

# =============================================================================
# Performance Tuning (SPEC-061)
# =============================================================================

# Concurrency limits
config :mimo_mcp,
       :max_concurrent_requests,
       String.to_integer(System.get_env("MAX_CONCURRENT_REQUESTS") || "100")

config :mimo_mcp,
       :max_skill_processes,
       String.to_integer(System.get_env("MAX_SKILL_PROCESSES") || "20")

config :mimo_mcp, :memory_cleanup_days, 30

# Embedding configuration
config :mimo_mcp, :embedding_dim, 1024

# SPEC-061: Embedding cache settings
config :mimo_mcp,
       :embedding_cache_size,
       String.to_integer(System.get_env("EMBEDDING_CACHE_SIZE") || "10000")

config :mimo_mcp,
       :embedding_cache_ttl_hours,
       String.to_integer(System.get_env("EMBEDDING_CACHE_TTL_HOURS") || "24")

# Latency targets (Universal Aperture)
config :mimo_mcp, :latency_target_ms, 50
config :mimo_mcp, :latency_warn_ms, 40

# SPEC-061: Production latency targets (for monitoring/alerting)
config :mimo_mcp,
       :p95_latency_target_ms,
       String.to_integer(System.get_env("P95_LATENCY_TARGET_MS") || "1500")

config :mimo_mcp,
       :p99_latency_target_ms,
       String.to_integer(System.get_env("P99_LATENCY_TARGET_MS") || "3000")

config :mimo_mcp,
       :throughput_target_rps,
       String.to_integer(System.get_env("THROUGHPUT_TARGET_RPS") || "100")

# =============================================================================
# Feature Flags
# =============================================================================

# SPEC-058: Reasoning-memory integration
config :mimo_mcp,
       :reasoning_memory_enabled,
       System.get_env("REASONING_MEMORY_ENABLED", "false") == "true"

# SPEC-061: Enable profiling in production (for debugging)
config :mimo_mcp, :profiling_enabled, System.get_env("PROFILING_ENABLED", "false") == "true"
