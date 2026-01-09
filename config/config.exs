import Config

# Ecto repos
config :mimo_mcp, ecto_repos: [Mimo.Repo]

# Phoenix JSON library
config :phoenix, :json_library, Jason

# =============================================================================
# Auto-Memory Configuration
# =============================================================================
# Automatically store memories from tool interactions
config :mimo_mcp,
  auto_memory_enabled: true,
  auto_memory_min_importance: 0.3

# =============================================================================
# Phase 3: Auto-Context Injection Configuration
# =============================================================================
# Fine-grained control over automatic context injection behaviors

config :mimo_mcp, :auto_context,
  # Master enable/disable for proactive knowledge injection (SPEC-065)
  pre_tool_injection: {:system, "AUTO_CONTEXT_INJECTION", true},
  # Auto-memory for file write summaries (Phase 3 enhancement)
  file_write_summaries: true,
  # Session state tracking in WorkingMemory
  session_state_tracking: true,
  # Maximum memories to inject per tool call
  max_injection_items: 5,
  # Minimum relevance threshold for injection
  injection_threshold: 0.7,
  # Include user patterns in injection
  include_patterns: true,
  # Include warnings in injection
  include_warnings: true

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

# Decay Rates (SPEC-003)
# NOTE: These rates are MANUALLY TUNED based on intuition, NOT empirically validated.
# See docs/ANTI-SLOP.md for discussion of this limitation.
config :mimo_mcp, :decay_rates,
  # Importance >= 0.9: ~693 days half-life (protected memories)
  critical: 0.0001,
  # Importance >= 0.7: ~69 days half-life
  high: 0.001,
  # Importance >= 0.5: ~14 days half-life
  medium: 0.005,
  # Importance >= 0.3: ~3.5 days half-life
  low: 0.02,
  # Importance < 0.3: ~17 hours half-life
  ephemeral: 0.1

# Hebbian Learning Rate Limiting (SPEC-088)
# Controls graph edge creation rate to prevent database bloat
config :mimo_mcp, :hebbian_learning,
  # Maximum new edges created per hour (500 = ~1GB/year at 240 bytes/edge)
  # Set to 0 to disable rate limiting, nil to use default (500)
  max_edges_per_hour: 500

# Hybrid Retrieval (SPEC-004)
# NOTE: These weights are MANUALLY TUNED based on intuition, NOT empirically validated.
# No A/B testing has been performed. See docs/ANTI-SLOP.md for discussion.
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
  websocket_synapse: {:system, "WEBSOCKET_ENABLED", false},
  # HNSW Index for O(log n) vector search (SPEC-033)
  hnsw_index: {:system, "HNSW_INDEX_ENABLED", false},
  # Temporal Memory Chains for brain-inspired memory reconsolidation (SPEC-034)
  temporal_memory_chains: {:system, "TMC_ENABLED", true},
  # Reasoning-Memory Integration for enhanced ingestion and retrieval (SPEC-058)
  reasoning_memory_integration: {:system, "REASONING_MEMORY_ENABLED", false}

# =============================================================================
# Reasoning-Memory Integration Configuration (SPEC-058)
# =============================================================================
# Fine-grained controls for reasoning-enhanced memory operations

config :mimo_mcp,
  # Master switch for reasoning-memory integration
  reasoning_memory_enabled: false

config :mimo_mcp, :reasoning_memory,
  # Ingestion path
  analyze_on_store: true,
  score_importance: true,
  detect_relationships: true,
  generate_tags: true,
  # Retrieval path (disabled by default, enable after validation)
  analyze_queries: false,
  rerank_results: false,
  # Performance
  max_reasoning_timeout_ms: 10_000,
  fallback_on_timeout: true

# =============================================================================
# Vector Search V3.0 Configuration (SPEC-033)
# =============================================================================
# Strategy selection for memory search based on corpus size

config :mimo_mcp, :vector_search,
  # Default strategy: :auto | :hnsw | :binary_rescore | :exact
  default_strategy: :auto,

  # Binary pre-filter settings (Phase 3a)
  # Fetch N * limit candidates for rescore
  binary_candidates_multiplier: 10,

  # HNSW settings (Phase 3b)
  hnsw_index_path: "priv/hnsw_index.usearch",
  # M parameter (edges per node)
  hnsw_connectivity: 16,
  # Build quality (higher = better but slower)
  hnsw_ef_construction: 128,
  # Search quality (higher = better but slower)
  hnsw_ef_search: 64,

  # Auto-strategy thresholds (Phase 3c)
  # Use HNSW above this memory count
  hnsw_threshold: 1000,
  # Use binary pre-filter above this memory count (when HNSW unavailable)
  binary_threshold: 500

# =============================================================================
# Autonomous Task Execution Configuration (SPEC-071)
# =============================================================================
# Configuration for the autonomous task runner

config :mimo_mcp, :autonomous,
  # Enable autonomous task execution
  enabled: true,
  # How often to check for queued tasks (10 seconds)
  check_interval: 10_000,
  # Maximum concurrent task executions
  max_concurrent: 3,
  # Task execution timeout (5 minutes)
  task_timeout: 300_000,
  # Circuit breaker: max consecutive failures before opening
  max_failures: 3,
  # Circuit breaker: cooldown period after opening (30 seconds)
  cooldown_ms: 30_000

# Import environment specific config
import_config "#{config_env()}.exs"
