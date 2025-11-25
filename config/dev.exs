import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :mimo_mcp, Mimo.Repo,
  database: "priv/mimo_mcp_dev.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
