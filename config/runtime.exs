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

# Database (runtime override)
if config_env() == :prod do
  config :mimo_mcp, Mimo.Repo,
    database: System.get_env("DB_PATH") || "priv/mimo_mcp.db",
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
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
# Existing Configuration
# =============================================================================

# Ollama (local embeddings)
config :mimo_mcp, :ollama_url, System.get_env("OLLAMA_URL") || "http://localhost:11434"

# OpenRouter (remote reasoning)
config :mimo_mcp, :openrouter_api_key, System.get_env("OPENROUTER_API_KEY")

# Skills
config :mimo_mcp, :skills_path, System.get_env("SKILLS_PATH") || "priv/skills.json"

# MCP Server (stdio)
config :mimo_mcp, :mcp_port, String.to_integer(System.get_env("MCP_PORT") || "9000")

# =============================================================================
# Performance Tuning for 12GB VPS
# =============================================================================
config :mimo_mcp, :max_concurrent_requests, 50
config :mimo_mcp, :max_skill_processes, 10
config :mimo_mcp, :memory_cleanup_days, 30

# Embedding dimensions (qwen3-embedding:0.6b uses 1024)
config :mimo_mcp, :embedding_dim, 1024

# Latency targets (Universal Aperture)
config :mimo_mcp, :latency_target_ms, 50
config :mimo_mcp, :latency_warn_ms, 40
