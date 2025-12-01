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
    limit = args["limit"] || 10

    if query == "" do
      {:error, "Search query is required"}
    else
      # First search local cache
      cached_results = Mimo.Library.Index.search(query, ecosystem: ecosystem, limit: limit)

      # If no cached results, search external API and cache results
      if Enum.empty?(cached_results) do
        search_external_and_cache(query, ecosystem, limit)
      else
        {:ok,
         %{
           query: query,
           ecosystem: ecosystem,
           results: cached_results,
           count: length(cached_results),
           source: :cache
         }}
      end
    end
  end

  # Search external package registry and cache top results
  defp search_external_and_cache(query, ecosystem, limit) do
    fetcher =
      case ecosystem do
        :hex -> Mimo.Library.Fetchers.HexFetcher
        :pypi -> Mimo.Library.Fetchers.PyPIFetcher
        :npm -> Mimo.Library.Fetchers.NPMFetcher
        :crates -> Mimo.Library.Fetchers.CratesFetcher
      end

    case fetcher.search(query, size: limit, per_page: limit) do
      {:ok, results} when is_list(results) ->
        # Cache top results in background for future searches
        spawn(fn ->
          results
          |> Enum.take(3)
          |> Enum.each(fn pkg ->
            name = pkg[:name] || pkg["name"]
            if name, do: Mimo.Library.Index.ensure_cached(name, ecosystem, [])
          end)
        end)

        # Format results consistently
        formatted =
          Enum.map(results, fn pkg ->
            %{
              name: pkg[:name] || pkg["name"],
              description: pkg[:description] || pkg["description"] || "",
              version:
                pkg[:version] || pkg["version"] || pkg[:latest_version] || pkg["latest_version"],
              url: pkg[:url] || pkg["url"],
              type: :package
            }
          end)

        {:ok,
         %{
           query: query,
           ecosystem: ecosystem,
           results: formatted,
           count: length(formatted),
           source: :external
         }}

      {:ok, _} ->
        {:ok, %{query: query, ecosystem: ecosystem, results: [], count: 0, source: :external}}

      {:error, reason} ->
        # Fallback to empty result with error info
        {:ok,
         %{
           query: query,
           ecosystem: ecosystem,
           results: [],
           count: 0,
           source: :external,
           error: inspect(reason)
         }}
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
