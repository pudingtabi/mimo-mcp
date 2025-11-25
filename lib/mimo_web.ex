defmodule MimoWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use MimoWeb, :controller
      use MimoWeb, :router
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json]

      import Plug.Conn
      alias MimoWeb.Router.Helpers, as: Routes
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MimoWeb.Endpoint,
        router: MimoWeb.Router,
        statics: MimoWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
