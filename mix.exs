defmodule Mimo.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimo_mcp,
      version: "2.7.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      compilers: Mix.compilers(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test, "coveralls.html": :test]]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto, :inets, :ssl],
      mod: {Mimo.Application, []},
      env: [
        sandbox_root: System.get_env("MIMO_ROOT") || File.cwd!(),
        max_file_size_mb: 10,
        command_timeout_ms: 30_000,
        restricted_mode: true
      ]
    ]
  end

  def releases do
    [
      mimo: [
        # , &Burrito.wrap/1],
        steps: [:assemble]
        # burrito: [
        #   targets: [
        #     macos_x86_64: [os: :darwin, cpu: :x86_64],
        #     macos_aarch64: [os: :darwin, cpu: :aarch64],
        #     linux_x86_64: [os: :linux, cpu: :x86_64],
        #     linux_aarch64: [os: :linux, cpu: :aarch64],
        #     windows_x86_64: [os: :windows, cpu: :x86_64]
        #   ],
        #   debug: Mix.env() != :prod
        # ]
      ]
    ]
  end

  defp deps do
    [
      # --- Packaging ---
      {:burrito, "~> 1.0", optional: true, runtime: false},

      # --- Goldilocks Stack: Production-hardened dependencies ---
      # HTTP client (replaces HTTPoison)
      {:req, "~> 0.5.0"},
      # Brotli decompression (enables Req brotli support)
      {:brotli, "~> 0.3.1"},
      # HTML parser for LLM-optimized markdown
      {:floki, "~> 0.36.0"},
      # Non-blocking, zombie-free process manager
      {:exile, "~> 0.10.0"},
      # Connection pool tuning (WSL networking)
      {:finch, "~> 0.18.0"},

      # --- Existing Core Dependencies ---
      # Database
      {:ecto, "~> 3.10.0", override: true},
      {:ecto_sql, "~> 3.10.0"},
      {:ecto_sqlite3, "~> 0.12.0"},
      {:exqlite, "~> 0.13.0", override: true},

      # JSON handling
      {:jason, "~> 1.4"},

      # Phoenix HTTP/REST Gateway
      {:phoenix, "~> 1.6.0"},
      {:plug_cowboy, "~> 2.5"},

      # Telemetry & Metrics
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Utilities
      {:uuid, "~> 1.1"},
      {:cors_plug, "~> 3.0"},

      # File system watching for Living Codebase
      {:file_system, "~> 1.0"},

      # Rust NIF support
      {:rustler, "~> 0.31", optional: true},

      # Dev/Test
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      # {:burrito, "~> 1.0", optional: true, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},

      # Prometheus metrics
      {:telemetry_metrics_prometheus, "~> 1.1"}
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
