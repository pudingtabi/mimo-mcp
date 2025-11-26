defmodule MimoWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for the Universal Aperture HTTP Gateway.

  Serves as the HTTP/REST adapter in the Hexagonal Architecture.
  Also provides WebSocket support for the Cortex Synapse channel.
  """
  use Phoenix.Endpoint, otp_app: :mimo_mcp

  # WebSocket for Cortex Channel (real-time cognitive signaling)
  socket("/cortex", MimoWeb.CortexSocket,
    websocket: [
      timeout: 45_000,
      compress: true,
      check_origin: false
    ],
    longpoll: false
  )

  # Session configuration (minimal - API is stateless)
  @session_options [
    store: :cookie,
    key: "_mimo_key",
    signing_salt: "mimo_salt",
    same_site: "Lax"
  ]

  # CORS support for browser-based clients
  plug(CORSPlug,
    origin: ["http://localhost:*", "http://127.0.0.1:*"],
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type", "Accept"]
  )

  # Parse JSON request bodies
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  plug(MimoWeb.Router)
end
