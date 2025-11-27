import Config

# Send logs to stderr so they don't mix with JSON-RPC on stdout
config :logger, :console,
  device: :standard_error,
  level: :info

# =============================================================================
# Universal Aperture: Production Configuration
# =============================================================================

# Phoenix HTTP endpoint for production
# Most settings are overridden in runtime.exs from environment variables
config :mimo_mcp, MimoWeb.Endpoint,
  url: [host: "localhost"],
  server: true

# Phoenix JSON library
config :phoenix, :json_library, Jason

# Disable debug logging in production
config :phoenix, :logger, false

# =============================================================================
# Resource Monitor Alerting Configuration
# =============================================================================
# These thresholds trigger warnings in ResourceMonitor
# and can be used for external alerting via Prometheus/Grafana
config :mimo_mcp, :alerting,
  # Memory thresholds
  # Warn when memory > 800MB
  memory_warning_mb: 800,
  # Critical alert > 1000MB sustained > 5min
  memory_critical_mb: 1000,

  # Process thresholds
  # Warn when process count > 400
  process_warning: 400,
  # Critical when > 500 sustained
  process_critical: 500,

  # Port thresholds (detect port leaks)
  # Warn when port count > 80
  port_warning: 80,
  # Critical when > 100
  port_critical: 100,

  # ETS table thresholds
  # Warn when any table > 8000 entries
  ets_warning_entries: 8000,
  # Critical when > 10000 entries
  ets_critical_entries: 10000,

  # Alerting intervals
  # 5 minutes sustained before critical
  sustained_alert_duration_s: 300,
  # Check every 30 seconds
  check_interval_ms: 30_000

# =============================================================================
# Feature Flags for Production
# =============================================================================
config :mimo_mcp, :feature_flags,
  rust_nifs: {:system, "RUST_NIFS_ENABLED", true},
  semantic_store: {:system, "SEMANTIC_STORE_ENABLED", true},
  procedural_store: {:system, "PROCEDURAL_STORE_ENABLED", true},
  websocket_synapse: {:system, "WEBSOCKET_ENABLED", true}

# =============================================================================
# Circuit Breaker Configuration
# =============================================================================
config :mimo_mcp, :circuit_breaker,
  llm_service: [
    failure_threshold: 5,
    reset_timeout_ms: 60_000,
    half_open_max_calls: 3
  ],
  database: [
    failure_threshold: 3,
    reset_timeout_ms: 30_000,
    half_open_max_calls: 2
  ],
  ollama: [
    failure_threshold: 5,
    reset_timeout_ms: 60_000,
    half_open_max_calls: 3
  ]
