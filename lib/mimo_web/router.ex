defmodule MimoWeb.Router do
  @moduledoc """
  HTTP Router for the Universal Aperture Protocol.

  Routes:
  - /v1/mimo/ask    - Natural language queries through Meta-Cognitive Router
  - /v1/mimo/tool   - Direct tool execution
  - /v1/chat/completions - OpenAI-compatible endpoint
  - /health         - Health check endpoint
  """
  use MimoWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(MimoWeb.Plugs.Telemetry)
    plug(MimoWeb.Plugs.RateLimiter)
  end

  pipeline :authenticated do
    plug(MimoWeb.Plugs.Authentication)
    plug(MimoWeb.Plugs.LatencyGuard)
  end

  # Health check - no auth required
  scope "/", MimoWeb do
    pipe_through(:api)
    get("/health", HealthController, :check)
  end

  # Mimo API v1 - requires authentication
  scope "/v1/mimo", MimoWeb do
    pipe_through([:api, :authenticated])

    post("/ask", AskController, :create)
    post("/tool", ToolController, :create)
    get("/tools", ToolController, :index)
  end

  # OpenAI-compatible endpoint
  scope "/v1", MimoWeb do
    pipe_through([:api, :authenticated])

    post("/chat/completions", OpenAIController, :create)
    get("/models", OpenAIController, :models)
  end

  # Catch-all for 404
  match(:*, "/*path", MimoWeb.FallbackController, :not_found)
end
