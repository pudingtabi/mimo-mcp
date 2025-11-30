defmodule Mimo.Library.Index do
  @moduledoc """
  Index for searching package documentation.

  Provides search capabilities across cached package documentation.
  """

  alias Mimo.Library.CacheManager
  require Logger

  @doc """
  Get package information.

  Fetches from cache if available, otherwise fetches from external API.
  """
  @spec get_package(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_package(name, ecosystem, opts \\ []) do
    version = opts[:version]

    case CacheManager.get(name, ecosystem, version) do
      {:ok, data} ->
        {:ok, data}

      {:error, _} ->
        # Fetch from external API
        fetch_and_cache(name, ecosystem, version)
    end
  end

  @doc """
  Search for functions/modules across cached packages.
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    ecosystem = opts[:ecosystem]
    package = opts[:package]
    limit = opts[:limit] || 20

    # Search through cached packages
    # This is a simplified implementation - would be more sophisticated with full-text search
    results =
      :ets.tab2list(:library_cache_hot)
      |> Enum.flat_map(fn {key, data, _expires} ->
        if ecosystem_matches?(key, ecosystem) and package_matches?(key, package) do
          search_in_package(data, query, key)
        else
          []
        end
      end)
      |> Enum.sort_by(fn result -> -result.score end)
      |> Enum.take(limit)

    results
  end

  @doc """
  Ensure a package is cached.
  """
  @spec ensure_cached(String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def ensure_cached(name, ecosystem, opts \\ []) do
    if CacheManager.cached?(name, ecosystem) do
      :ok
    else
      case get_package(name, ecosystem, opts) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  # Private helpers

  defp fetch_and_cache(name, ecosystem, version) do
    Logger.info("Fetching package documentation: #{ecosystem}/#{name}")

    fetcher = get_fetcher(ecosystem)
    opts = if version, do: [version: version], else: []

    case fetcher.fetch(name, opts) do
      {:ok, package_info} ->
        # Determine tier based on popularity
        tier =
          if name in CacheManager.popular_packages(ecosystem) do
            2
          else
            3
          end

        CacheManager.put(name, ecosystem, package_info, tier: tier, version: version)
        {:ok, package_info}

      {:error, reason} = error ->
        Logger.warning("Failed to fetch #{ecosystem}/#{name}: #{inspect(reason)}")
        error
    end
  end

  defp get_fetcher(:hex), do: Mimo.Library.Fetchers.HexFetcher
  defp get_fetcher(:pypi), do: Mimo.Library.Fetchers.PyPIFetcher
  defp get_fetcher(:npm), do: Mimo.Library.Fetchers.NPMFetcher
  defp get_fetcher(:crates), do: Mimo.Library.Fetchers.CratesFetcher

  defp ecosystem_matches?(_key, nil), do: true
  defp ecosystem_matches?(key, ecosystem), do: String.starts_with?(key, "#{ecosystem}/")

  defp package_matches?(_key, nil), do: true

  defp package_matches?(key, package) do
    # Key format: "ecosystem/package" or "ecosystem/package@version"
    parts = String.split(key, "/")

    if length(parts) >= 2 do
      pkg_part = Enum.at(parts, 1)
      pkg_name = String.split(pkg_part, "@") |> List.first()
      pkg_name == package
    else
      false
    end
  end

  defp search_in_package(data, query, package_key) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower)

    # Search in modules
    module_results =
      (data["modules"] || [])
      |> Enum.map(fn mod ->
        name = mod["name"] || ""
        doc = mod["doc"] || ""
        score = calculate_score(name, doc, query_lower, query_words)

        if score > 0 do
          %{
            type: :module,
            name: name,
            doc: String.slice(doc, 0, 200),
            package: package_key,
            score: score
          }
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Search in functions
    function_results =
      (data["functions"] || [])
      |> Enum.map(fn func ->
        name = func["name"] || ""
        doc = func["doc"] || ""
        module = func["module"] || ""
        score = calculate_score(name, doc, query_lower, query_words)

        if score > 0 do
          %{
            type: :function,
            name: name,
            module: module,
            signature: func["signature"],
            doc: String.slice(doc, 0, 200),
            package: package_key,
            score: score
          }
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    module_results ++ function_results
  end

  defp calculate_score(name, doc, query_lower, query_words) do
    name_lower = String.downcase(name)
    doc_lower = String.downcase(doc)

    # Exact name match: highest score
    cond do
      name_lower == query_lower ->
        100

      String.starts_with?(name_lower, query_lower) ->
        80

      String.contains?(name_lower, query_lower) ->
        60

      Enum.all?(query_words, &String.contains?(name_lower, &1)) ->
        50

      Enum.all?(query_words, &String.contains?(doc_lower, &1)) ->
        30

      Enum.any?(query_words, &String.contains?(name_lower, &1)) ->
        20

      Enum.any?(query_words, &String.contains?(doc_lower, &1)) ->
        10

      true ->
        0
    end
  end
end
