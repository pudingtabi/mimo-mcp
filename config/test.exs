import Config

# Use file-based SQLite test database that persists across ecto.create/migrate/test
# Pool size increased to handle background GenServers during initialization
config :mimo_mcp, Mimo.Repo,
  database: Path.expand("../priv/mimo_mcp_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 30,
  queue_target: 10_000,
  queue_interval: 20_000,
  ownership_timeout: 120_000,
  show_sensitive_data_on_connection_error: true

# Disable external API calls in tests
config :mimo_mcp,
  api_key: "test-key-for-ci-minimum-32-characters-long",
  openrouter_api_key: nil,
  skip_external_apis: true,
  # Skip instance lock to allow tests alongside running Mimo instance
  skip_instance_lock: true,
  # Use fast timeouts in tests
  ollama_timeout: 1_000,
  environment: :test,
  # Reduce background process activity during tests
  disable_background_cognition: true,
  disable_emergence_scheduler: true,
  disable_sleep_cycle: true

config :logger, level: :warning
