# Ensure the application is started before running tests
{:ok, _} = Application.ensure_all_started(:mimo_mcp)

ExUnit.start(exclude: [:integration, :external, :hnsw_nif])

# Load test support files
Code.require_file("support/data_case.ex", __DIR__)
Code.require_file("support/channel_case.ex", __DIR__)

# Configure Ecto SQL Sandbox for test isolation (only if Sandbox pool is configured)
repo_config = Application.get_env(:mimo_mcp, Mimo.Repo, [])

if Keyword.get(repo_config, :pool) == Ecto.Adapters.SQL.Sandbox do
  Ecto.Adapters.SQL.Sandbox.mode(Mimo.Repo, :manual)
else
  IO.warn(
    "⚠️  Mimo.Repo not configured with Ecto.Adapters.SQL.Sandbox pool. Tests may fail or interfere with each other."
  )
end
