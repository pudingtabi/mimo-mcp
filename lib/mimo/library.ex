defmodule Mimo.Library do
  @moduledoc """
  Universal Library module for external package documentation.

  Provides omniscient access to package documentation from Hex.pm, PyPI, and NPM.
  Part of SPEC-022 Living Knowledge Graph implementation.

  ## Features

  - Auto-detect project dependencies from mix.exs, requirements.txt, package.json
  - Fetch and cache package documentation
  - Tiered caching system (project deps > popular libs > on-demand)
  - Offline support with cached data

  ## Usage

      # Get package info
      {:ok, package} = Mimo.Library.get_package("phoenix", :hex)

      # Search for functions
      results = Mimo.Library.search("plug conn", ecosystem: :hex)

      # Scan project dependencies
      deps = Mimo.Library.scan_project("/path/to/project")
  """

  alias Mimo.Library.{CacheManager, DependencyDetector, Index}

  @type ecosystem :: :hex | :pypi | :npm
  @type package_info :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          ecosystem: ecosystem(),
          modules: [map()],
          functions: [map()]
        }

  @doc """
  Get package information and documentation.

  Will fetch from cache if available, otherwise fetches from external API.
  """
  @spec get_package(String.t(), ecosystem(), keyword()) ::
          {:ok, package_info()} | {:error, term()}
  def get_package(name, ecosystem, opts \\ []) do
    version = opts[:version]
    Index.get_package(name, ecosystem, version: version)
  end

  @doc """
  Search for functions/modules across cached packages.
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    Index.search(query, opts)
  end

  @doc """
  Scan a project directory to detect dependencies.

  Returns a list of detected dependencies with their ecosystems.
  """
  @spec scan_project(String.t()) :: [map()]
  def scan_project(project_path) do
    DependencyDetector.scan(project_path)
  end

  @doc """
  Ensure all project dependencies are cached.

  Scans the project and fetches documentation for all detected dependencies.
  """
  @spec cache_project_deps(String.t()) :: {:ok, map()} | {:error, term()}
  def cache_project_deps(project_path) do
    deps = scan_project(project_path)

    results =
      deps
      |> Task.async_stream(
        fn dep ->
          case get_package(dep.name, dep.ecosystem, version: dep.version) do
            {:ok, _} -> {:ok, dep.name}
            {:error, reason} -> {:error, {dep.name, reason}}
          end
        end,
        max_concurrency: 4,
        timeout: 30_000
      )
      |> Enum.reduce(%{success: [], failed: []}, fn
        {:ok, {:ok, name}}, acc -> %{acc | success: [name | acc.success]}
        {:ok, {:error, {name, _reason}}}, acc -> %{acc | failed: [name | acc.failed]}
        {:exit, _}, acc -> acc
      end)

    {:ok, results}
  end

  @doc """
  Get cache statistics.
  """
  @spec cache_stats() :: map()
  def cache_stats do
    CacheManager.stats()
  end

  @doc """
  Clear expired cache entries.
  """
  @spec cleanup_cache() :: {:ok, non_neg_integer()}
  def cleanup_cache do
    CacheManager.cleanup()
  end

  @doc """
  Force refresh a package's documentation.
  """
  @spec refresh_package(String.t(), ecosystem()) :: {:ok, package_info()} | {:error, term()}
  def refresh_package(name, ecosystem) do
    CacheManager.invalidate(name, ecosystem)
    get_package(name, ecosystem)
  end
end
