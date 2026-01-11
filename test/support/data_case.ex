defmodule Mimo.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Mimo.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Mimo.DataCase
    end
  end

  @doc """
  Start sandbox with retry to handle race conditions during parallel test startup.
  """
  def start_sandbox_with_retry(0), do: raise("Failed to start sandbox after retries")

  def start_sandbox_with_retry(attempts) do
    try do
      # Use shared mode to allow WriteSerializer and other GenServers to access the connection
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mimo.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    rescue
      e in DBConnection.ConnectionError ->
        Process.sleep(100)
        start_sandbox_with_retry(attempts - 1)

      e in ArgumentError ->
        # Repo not started yet - wait and retry
        Process.sleep(100)
        start_sandbox_with_retry(attempts - 1)
    end
  end

  setup tags do
    repo_config = Application.get_env(:mimo_mcp, Mimo.Repo, [])

    if Keyword.get(repo_config, :pool) == Ecto.Adapters.SQL.Sandbox do
      # Start sandbox with retry - handles race conditions during parallel test startup
      start_sandbox_with_retry(5)
    else
      # SAFEGUARD: Prevent tests from running against dev/prod DB without sandbox
      # This prevents catastrophic data loss if someone runs tests with MIX_ENV=dev
      db_path = Keyword.get(repo_config, :database, "")

      if String.contains?(db_path, "mimo_mcp.db") and not String.contains?(db_path, "test") do
        raise """
        FATAL: Tests attempting to run against non-test database!

        Database path: #{db_path}

        This would destroy all production/dev memories. Tests MUST run with:
          MIX_ENV=test mix test

        If you need to run specific tests in dev mode for debugging, use:
          MIX_ENV=test mix test test/path/to/specific_test.exs
        """
      end

      # Repo not configured for Sandbox; proceed without ownership to avoid crashes
      :ok
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
