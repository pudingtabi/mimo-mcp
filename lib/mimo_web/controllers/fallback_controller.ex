defmodule MimoWeb.FallbackController do
  @moduledoc """
  Fallback controller for handling 404s and other errors.
  """
  use MimoWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "Not found",
      path: conn.request_path,
      available_endpoints: [
        "GET /health",
        "POST /v1/mimo/ask",
        "POST /v1/mimo/tool",
        "GET /v1/mimo/tools",
        "POST /v1/chat/completions",
        "GET /v1/models"
      ]
    })
  end
end
