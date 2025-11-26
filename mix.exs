defmodule MimoMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimo_mcp,
      version: "2.3.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers: Mix.compilers()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto],
      mod: {Mimo.Application, []}
    ]
  end

  defp deps do
    [
      # Database - pinned to versions compatible with Elixir 1.12
      {:ecto, "~> 3.10.0", override: true},
      {:ecto_sql, "~> 3.10.0"},
      {:ecto_sqlite3, "~> 0.12.0"},
      {:exqlite, "~> 0.13.0", override: true},
      
      # JSON handling
      {:jason, "~> 1.4"},
      
      # HTTP client
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
      
      # Rust NIF support (Phase 2 - Vector Math)
      {:rustler, "~> 0.31", optional: true},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      reset: ["ecto.drop", "setup"],
      "cortex.migrate": ["ecto.migrate"],
      "cortex.status": &cortex_status/1
    ]
  end

  defp cortex_status(_) do
    Mix.shell().info("Synthetic Cortex Module Status:")
    Mix.shell().info("  Run `mix run -e 'IO.inspect(Mimo.Application.cortex_status())'`")
  end
end
