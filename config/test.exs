import Config

# Use file-based SQLite test database that persists across ecto.create/migrate/test
config :mimo_mcp, Mimo.Repo,
  database: Path.expand("../priv/mimo_mcp_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

# Disable external API calls in tests
config :mimo_mcp,
  api_key: "test-key-for-ci-minimum-32-characters-long",
  openrouter_api_key: nil,
  skip_external_apis: true,
  # Use fast timeouts in tests
  ollama_timeout: 1_000,
  environment: :test

config :logger, level: :warning
