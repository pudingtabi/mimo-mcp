defmodule Mimo.Repo do
  use Ecto.Repo,
    otp_app: :mimo_mcp,
    adapter: Ecto.Adapters.SQLite3
end
