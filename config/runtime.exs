import Config

# CRITICAL: Send logs to stderr so stdout remains clean for MCP JSON-RPC
config :logger, :console,
  device: :standard_error,
  format: "$time $metadata[$level] $message\n"

# Database (runtime override)
if config_env() == :prod do
  config :mimo_mcp, Mimo.Repo,
    database: System.get_env("DB_PATH") || "priv/mimo_mcp.db",
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end

# Ollama (local embeddings)
config :mimo_mcp, :ollama_url,
  System.get_env("OLLAMA_URL") || "http://localhost:11434"

# OpenRouter (remote reasoning)
config :mimo_mcp, :openrouter_api_key,
  System.get_env("OPENROUTER_API_KEY")

# Skills
config :mimo_mcp, :skills_path,
  System.get_env("SKILLS_PATH") || "priv/skills.json"

# MCP Server
config :mimo_mcp, :mcp_port,
  String.to_integer(System.get_env("MCP_PORT") || "9000")

# Performance tuning for 12GB VPS
config :mimo_mcp, :max_concurrent_requests, 50
config :mimo_mcp, :max_skill_processes, 10
config :mimo_mcp, :memory_cleanup_days, 30

# Embedding dimensions (nomic-embed-text uses 768)
config :mimo_mcp, :embedding_dim, 768
