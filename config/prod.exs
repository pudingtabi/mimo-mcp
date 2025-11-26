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
