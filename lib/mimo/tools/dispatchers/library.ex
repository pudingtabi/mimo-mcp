defmodule Mimo.Tools.Dispatchers.Library do
  @moduledoc """
  Library operations dispatcher.

  Handles package documentation lookup operations:
  - get: Fetch package info (Library.Index.get_package)
  - search: Search packages (Library.Index.search)
  - ensure: Ensure package is cached (Library.Index.ensure_cached)
  - discover: Auto-discover and cache deps (Library.AutoDiscovery.discover_and_cache)
  - stats: Cache statistics (Library.CacheManager.stats)

  Supports: Hex.pm (Elixir), PyPI (Python), NPM (JavaScript), crates.io (Rust)
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch library operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "get"

    case op do
      "get" ->
        dispatch_get(args)

      "search" ->
        dispatch_search(args)

      "ensure" ->
        dispatch_ensure(args)

      "discover" ->
        dispatch_discover(args)

      "stats" ->
        {:ok, Mimo.Library.CacheManager.stats()}

      _ ->
        {:error, "Unknown library operation: #{op}"}
    end
  end

  # ==========================================================================
  # PRIVATE HELPERS
  # ==========================================================================

  defp dispatch_get(args) do
    name = args["name"]
    ecosystem = Helpers.parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Mimo.Library.Index.get_package(name, ecosystem, opts) do
        {:ok, package} ->
          {:ok, Helpers.format_package(package)}

        {:error, :not_found} ->
          {:ok, %{name: name, ecosystem: ecosystem, found: false}}

        error ->
          error
      end
    end
  end

  defp dispatch_search(args) do
    query = args["query"] || args["name"] || ""
    ecosystem = Helpers.parse_ecosystem(args["ecosystem"] || "hex")

    if query == "" do
      {:error, "Search query is required"}
    else
      results = Mimo.Library.Index.search(query, ecosystem: ecosystem, limit: args["limit"] || 10)
      {:ok, %{query: query, ecosystem: ecosystem, results: results, count: length(results)}}
    end
  end

  defp dispatch_ensure(args) do
    name = args["name"]
    ecosystem = Helpers.parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Mimo.Library.Index.ensure_cached(name, ecosystem, opts) do
        :ok ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: true}}

        {:error, reason} ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: false, error: inspect(reason)}}
      end
    end
  end

  defp dispatch_discover(args) do
    path = args["path"] || File.cwd!()

    case Mimo.Library.AutoDiscovery.discover_and_cache(path) do
      {:ok, result} ->
        {:ok,
         %{
           path: path,
           ecosystems: result.ecosystems,
           total_dependencies: result.total_dependencies,
           cached_successfully: result.cached_successfully,
           failed: result.failed
         }}

      {:error, reason} ->
        {:error, "Discovery failed: #{reason}"}
    end
  end
end
