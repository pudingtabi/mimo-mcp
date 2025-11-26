import Config

# Ecto repos
config :mimo_mcp, ecto_repos: [Mimo.Repo]

# =============================================================================
# Synthetic Cortex Feature Flags
# =============================================================================
# Enable/disable Phase 2 & 3 modules for zero-downtime migration
# Can be overridden via environment variables

config :mimo_mcp, :feature_flags,
  # Rust NIFs for SIMD-accelerated vector operations
  rust_nifs: {:system, "RUST_NIFS_ENABLED", false},
  # Semantic Store for triple-based knowledge graph
  semantic_store: {:system, "SEMANTIC_STORE_ENABLED", false},
  # Procedural Store for deterministic state machine execution
  procedural_store: {:system, "PROCEDURAL_STORE_ENABLED", false},
  # WebSocket Synapse for real-time cognitive signaling
  websocket_synapse: {:system, "WEBSOCKET_ENABLED", false}

# Import environment specific config
import_config "#{config_env()}.exs"
