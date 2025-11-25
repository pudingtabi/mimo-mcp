import Config

# Send logs to stderr so they don't mix with JSON-RPC on stdout
config :logger, :console,
  device: :standard_error,
  level: :info
