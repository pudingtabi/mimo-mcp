defmodule MimoWeb.Plugs.Authentication do
  @moduledoc """
  API Key authentication plug for the Universal Aperture.
  
  Validates Bearer token against MIMO_API_KEY environment variable.
  Supports sandbox mode for untrusted scripts.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    api_key = Application.get_env(:mimo_mcp, :api_key)
    
    # If no API key configured, allow all requests (development mode)
    if is_nil(api_key) or api_key == "" do
      Logger.debug("No API key configured, allowing request")
      conn
    else
      case get_bearer_token(conn) do
        {:ok, token} when token == api_key ->
          # Check for sandbox mode
          conn = if get_req_header(conn, "x-mimo-sandbox") != [] do
            assign(conn, :sandbox_mode, true)
          else
            assign(conn, :sandbox_mode, false)
          end
          conn
          
        {:ok, _invalid_token} ->
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{error: "Invalid API key"})
          |> halt()
          
        :error ->
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{error: "Missing Authorization header"})
          |> halt()
      end
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
