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

  setup tags do
    repo_config = Application.get_env(:mimo_mcp, Mimo.Repo, [])

    if Keyword.get(repo_config, :pool) == Ecto.Adapters.SQL.Sandbox do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mimo.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    else
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
