defmodule MimoWeb.ChannelCase do
  @moduledoc """
  This module defines the setup for tests requiring
  channel/websocket functionality.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common channel test setup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import MimoWeb.ChannelCase

      # The default endpoint for testing
      @endpoint MimoWeb.Endpoint
    end
  end

  setup tags do
    # Set up database sandbox if needed
    if tags[:db] do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mimo.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    end

    :ok
  end
end
