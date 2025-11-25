import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :mimo_mcp, Mimo.Repo,
  database: "priv/mimo_mcp_dev.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# =============================================================================
# Universal Aperture: Development Configuration
# =============================================================================

# Phoenix HTTP endpoint for development
config :mimo_mcp, MimoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "mimo_dev_secret_key_base_32_chars_min_for_security_please_change_in_production",
  server: true

# No API key required in development
config :mimo_mcp, :api_key, nil

# Phoenix JSON library
config :phoenix, :json_library, Jason
