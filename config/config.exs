import Config

# Ecto repos
config :mimo_mcp, ecto_repos: [Mimo.Repo]

# Import environment specific config
import_config "#{config_env()}.exs"
