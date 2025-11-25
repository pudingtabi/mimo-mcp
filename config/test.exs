import Config

config :mimo_mcp, Mimo.Repo,
  database: "priv/mimo_mcp_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning
