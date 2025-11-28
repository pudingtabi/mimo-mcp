import Config

# Ecto repos
config :mimo_mcp, ecto_repos: [Mimo.Repo]

# =============================================================================
# Auto-Memory Configuration
# =============================================================================
# Automatically store memories from tool interactions
config :mimo_mcp,
  auto_memory_enabled: true,
  auto_memory_min_importance: 0.3

# =============================================================================
# Cognitive Memory System Configuration (SPEC-001 to SPEC-005)
# =============================================================================

# Working Memory (SPEC-001)
config :mimo_mcp, :working_memory,
  # Default TTL for working memory items (5 minutes)
  default_ttl: 300_000,
  # Maximum items in working memory (prevents unbounded growth)
  max_items: 1000,
  # Cleanup interval for expired items (30 seconds)
  cleanup_interval: 30_000

# Memory Consolidation (SPEC-002)
config :mimo_mcp, :consolidation,
  # Enable consolidation system
  enabled: true,
  # How often to check for consolidation candidates (1 minute)
  interval_ms: 60_000,
  # Minimum consolidation score to transfer to long-term
  score_threshold: 0.3,
  # Minimum age before eligible for consolidation (30 seconds)
  min_age_ms: 30_000

# Forgetting/Decay (SPEC-003)
config :mimo_mcp, :forgetting,
  # Enable forgetting system
  enabled: true,
  # How often to run forgetting cycle (1 hour)
  interval_ms: 3_600_000,
  # Score threshold below which memories are forgotten
  threshold: 0.1,
  # Process N memories per cycle
  batch_size: 1000,
  # Dry run mode (log but don't delete)
  dry_run: false

# Hybrid Retrieval (SPEC-004)
config :mimo_mcp, :hybrid_scoring,
  # Weight for vector similarity in hybrid score
  vector_weight: 0.35,
  # Weight for recency in hybrid score
  recency_weight: 0.25,
  # Weight for access frequency in hybrid score
  access_weight: 0.15,
  # Weight for importance in hybrid score
  importance_weight: 0.15,
  # Weight for graph connectivity in hybrid score
  graph_weight: 0.10

config :mimo_mcp, :hybrid_retrieval,
  # Candidates to fetch from vector search
  vector_limit: 20,
  # Candidates to fetch from graph search
  graph_limit: 10,
  # Candidates to fetch from recency search
  recency_limit: 10,
  # Final result limit
  final_limit: 10

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
