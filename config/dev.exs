import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :mimo_mcp, Mimo.Repo,
  database: System.get_env("MIMO_DB_PATH") || "priv/mimo_mcp.db",
  # SPEC-STABILITY: SQLite only allows ONE writer at a time.
  # pool_size > 1 causes "Database busy" errors even with WriteSerializer
  # because multiple connections can attempt concurrent writes.
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  # SQLite concurrency settings for concurrent access
  busy_timeout: 120_000,
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory,
  # Enable shared cache for better concurrent reads
  mode: :readwrite

# =============================================================================
# Universal Aperture: Development Configuration
# =============================================================================

# Phoenix HTTP endpoint for development
config :mimo_mcp, MimoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base:
    System.get_env("MIMO_SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(32)),
  server: true

# No API key required in development
config :mimo_mcp, :api_key, nil

# Phoenix JSON library
config :phoenix, :json_library, Jason

# =============================================================================
# Feature Flags - Enable all features (same as prod)
# =============================================================================
config :mimo_mcp, :feature_flags,
  rust_nifs: true,
  semantic_store: true,
  procedural_store: true,
  websocket_synapse: true,
  hnsw_index: true,
  temporal_memory_chains: true

# =============================================================================
# CRITICAL: Memory Retention Overrides for Development
# =============================================================================
# The default TTL settings are too aggressive for development/learning.
# This preserves memories much longer to enable actual cognitive capabilities.

# Disable aggressive Cleanup in dev - keep memories for 365 days
config :mimo_mcp, Mimo.Brain.Cleanup,
  # Keep all memories for 1 year (was 30 days)
  default_ttl_days: 365,
  # Keep low-importance for 90 days (was 7 days)
  low_importance_ttl_days: 90,
  # Allow more memories (was 100,000)
  max_memory_count: 500_000,
  # Run only once per day, not hourly
  cleanup_interval_ms: 86_400_000

# Adjust Forgetting to be less aggressive
config :mimo_mcp, :forgetting,
  enabled: true,
  # Daily instead of hourly
  interval_ms: 86_400_000,
  # Lower threshold - only forget truly decayed memories
  threshold: 0.05,
  # Smaller batches
  batch_size: 100,
  dry_run: false
