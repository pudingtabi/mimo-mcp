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
  alias Mimo.Utils.InputValidation

  @doc """
  Dispatch library operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "get"
    do_dispatch(op, args)
  end

  # Multi-head dispatch
  defp do_dispatch("get", args), do: dispatch_get(args)
  defp do_dispatch("search", args), do: dispatch_search(args)
  defp do_dispatch("ensure", args), do: dispatch_ensure(args)
  defp do_dispatch("discover", args), do: dispatch_discover(args)
  defp do_dispatch("stats", _args), do: {:ok, Mimo.Library.CacheManager.stats()}
  defp do_dispatch(op, _args), do: {:error, "Unknown library operation: #{op}"}

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
    # Validate limit
    limit = InputValidation.validate_limit(args["limit"], default: 10, max: 100)

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
    fetcher = fetcher_for_ecosystem(ecosystem)

    case fetcher.search(query, size: limit, per_page: limit) do
      {:ok, results} when is_list(results) ->
        cache_top_results_async(results, ecosystem)
        formatted = Enum.map(results, &format_search_result/1)

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

  # Multi-head fetcher lookup
  defp fetcher_for_ecosystem(:hex), do: Mimo.Library.Fetchers.HexFetcher
  defp fetcher_for_ecosystem(:pypi), do: Mimo.Library.Fetchers.PyPIFetcher
  defp fetcher_for_ecosystem(:npm), do: Mimo.Library.Fetchers.NPMFetcher
  defp fetcher_for_ecosystem(:crates), do: Mimo.Library.Fetchers.CratesFetcher

  defp cache_top_results_async(results, ecosystem) do
    spawn(fn ->
      results
      |> Enum.take(3)
      |> Enum.each(fn pkg ->
        name = pkg[:name] || pkg["name"]
        if name, do: Mimo.Library.Index.ensure_cached(name, ecosystem, [])
      end)
    end)
  end

  defp format_search_result(pkg) do
    %{
      name: pkg[:name] || pkg["name"],
      description: pkg[:description] || pkg["description"] || "",
      version: pkg[:version] || pkg["version"] || pkg[:latest_version] || pkg["latest_version"],
      url: pkg[:url] || pkg["url"],
      type: :package
    }
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
