defmodule MimoMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimo_mcp,
      version: "2.2.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers: Mix.compilers()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Mimo.Application, []}
    ]
  end

  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.7"},
      {:ecto_sqlite3, "~> 0.8.0"},
      
      # JSON handling
      {:jason, "~> 1.4"},
      
      # HTTP client - use hackney with ssl_verify_fun disabled for older OTP
      # Full environment (VPS/Docker) should have proper OTP with public_key
      {:httpoison, "~> 1.8"},
      {:hackney, "~> 1.18", override: true},
      
      # Phoenix HTTP/REST Gateway (Universal Aperture)
      {:phoenix, "~> 1.6.0"},
      {:plug_cowboy, "~> 2.5"},
      
      # Telemetry & Metrics
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      
      # UUID generation
      {:uuid, "~> 1.1"},
      
      # CORS support for browser clients
      {:cors_plug, "~> 3.0"},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      reset: ["ecto.drop", "setup"]
    ]
  end
end
