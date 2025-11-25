defmodule MimoMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimo_mcp,
      version: "2.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Mimo.Application, []}
    ]
  end

  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.15.0"},
      
      # JSON handling
      {:jason, "~> 1.4"},
      
      # HTTP client
      {:req, "~> 0.4.0"},
      
      # Note: hermes_mcp commented out - using custom stdio MCP server
      # Uncomment if package becomes available on hex.pm:
      # {:hermes_mcp, "~> 0.3.0"},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      reset: ["ecto.drop", "setup"]
    ]
  end
end
