# Ensure the application is started before running tests
{:ok, _} = Application.ensure_all_started(:mimo_mcp)

# Wait for Repo to be fully ready before configuring sandbox
defmodule TestStartupHelper do
  def await_repo(attempts \\ 20) do
    case Process.whereis(Mimo.Repo) do
      nil when attempts > 0 ->
        Process.sleep(100)
        await_repo(attempts - 1)

      nil ->
        raise "Mimo.Repo did not start within 2 seconds"

      pid when is_pid(pid) ->
        # Repo process exists, verify it's alive and responsive
        if Process.alive?(pid) do
          :ok
        else
          if attempts > 0 do
            Process.sleep(100)
            await_repo(attempts - 1)
          else
            raise "Mimo.Repo process is not alive"
          end
        end
    end
  end
end

TestStartupHelper.await_repo()

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
