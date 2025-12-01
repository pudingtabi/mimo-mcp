defmodule Mimo.Library.Index do
  @moduledoc """
  Index for searching package documentation.

  Provides search capabilities across cached package documentation.
  Handles different data structures from Hex, NPM, PyPI, and Crates ecosystems.
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
    results =
      :ets.tab2list(:library_cache_hot)
      |> Enum.flat_map(fn {key, data, _expires} ->
        if ecosystem_matches?(key, ecosystem) and package_matches?(key, package) do
          detected_ecosystem = detect_ecosystem(key)
          search_in_package(data, query, key, detected_ecosystem)
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

  defp detect_ecosystem(key) do
    cond do
      String.starts_with?(key, "hex/") -> :hex
      String.starts_with?(key, "pypi/") -> :pypi
      String.starts_with?(key, "npm/") -> :npm
      String.starts_with?(key, "crates/") -> :crates
      true -> :unknown
    end
  end

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

  defp search_in_package(data, query, package_key, ecosystem) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower)

    # Get searchable items based on ecosystem
    items = extract_searchable_items(data, ecosystem, package_key)

    # Score and filter items
    items
    |> Enum.map(fn item ->
      name = item[:name] || ""
      doc = item[:doc] || ""
      score = calculate_score(name, doc, query_lower, query_words)

      if score > 0 do
        Map.put(item, :score, score)
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Extract searchable items based on ecosystem-specific data structures
  defp extract_searchable_items(data, :hex, package_key) do
    # Hex: modules with optional functions
    modules = get_value(data, "modules", [])

    module_items =
      Enum.map(modules, fn mod ->
        %{
          type: :module,
          name: get_value(mod, "name", ""),
          doc: get_value(mod, "doc", "") |> truncate_doc(),
          package: package_key
        }
      end)

    # Also extract functions if present
    function_items =
      modules
      |> Enum.flat_map(fn mod ->
        module_name = get_value(mod, "name", "")
        functions = get_value(mod, "functions", [])

        Enum.map(functions, fn func ->
          %{
            type: :function,
            name: get_value(func, "name", ""),
            module: module_name,
            signature: get_value(func, "spec"),
            doc: get_value(func, "doc", "") |> truncate_doc(),
            package: package_key
          }
        end)
      end)

    module_items ++ function_items
  end

  defp extract_searchable_items(data, :pypi, package_key) do
    # PyPI: modules with optional classes
    modules = get_value(data, "modules", [])

    Enum.map(modules, fn mod ->
      %{
        type: :module,
        name: get_value(mod, "name", ""),
        doc: get_value(mod, "doc", "") |> truncate_doc(),
        package: package_key
      }
    end)
  end

  defp extract_searchable_items(data, :npm, package_key) do
    items = []

    # NPM: exports, types definitions
    # Search in exports
    exports = get_value(data, "exports", [])

    export_items =
      Enum.map(exports, fn exp ->
        %{
          type: :export,
          name: get_value(exp, "name", ""),
          doc: get_value(exp, "doc", "") |> truncate_doc(),
          package: package_key
        }
      end)

    # Search in TypeScript type definitions
    types = get_value(data, "types")
    type_items = extract_npm_type_items(types, package_key)

    # Also search in package description and name for basic matching
    pkg_name = get_value(data, "name", "")
    pkg_desc = get_value(data, "description", "")

    pkg_item =
      if pkg_name != "" do
        [
          %{
            type: :package,
            name: pkg_name,
            doc: pkg_desc |> truncate_doc(),
            package: package_key
          }
        ]
      else
        []
      end

    items ++ export_items ++ type_items ++ pkg_item
  end

  defp extract_searchable_items(data, :crates, package_key) do
    # Crates: modules (if present)
    modules = get_value(data, "modules", [])

    module_items =
      Enum.map(modules, fn mod ->
        %{
          type: :module,
          name: get_value(mod, "name", ""),
          doc: get_value(mod, "doc", "") |> truncate_doc(),
          package: package_key
        }
      end)

    # Also include package itself for basic matching
    pkg_name = get_value(data, "name", "")
    pkg_desc = get_value(data, "description", "")

    pkg_item =
      if pkg_name != "" do
        [
          %{
            type: :package,
            name: pkg_name,
            doc: pkg_desc |> truncate_doc(),
            package: package_key
          }
        ]
      else
        []
      end

    module_items ++ pkg_item
  end

  defp extract_searchable_items(data, _unknown, package_key) do
    # Fallback: try to extract any modules or functions
    modules = get_value(data, "modules", [])

    Enum.map(modules, fn mod ->
      %{
        type: :module,
        name: get_value(mod, "name", ""),
        doc: get_value(mod, "doc", "") |> truncate_doc(),
        package: package_key
      }
    end)
  end

  defp extract_npm_type_items(nil, _package_key), do: []

  defp extract_npm_type_items(types, package_key) when is_map(types) do
    # Extract from TypeScript modules
    modules = get_value(types, "modules", []) ++ get_value(types, :modules, [])

    Enum.flat_map(modules, fn type_module ->
      module_name = get_value(type_module, "name", get_value(type_module, :name, "default"))
      exports = get_value(type_module, "exports", get_value(type_module, :exports, []))

      Enum.map(exports, fn exp ->
        %{
          type: :type_export,
          name: get_value(exp, "name", get_value(exp, :name, "")),
          kind: get_value(exp, "kind", get_value(exp, :kind)),
          signature: get_value(exp, "signature", get_value(exp, :signature)),
          doc: (get_value(exp, "doc", get_value(exp, :doc, "")) || "") |> truncate_doc(),
          module: module_name,
          package: package_key
        }
      end)
    end)
  end

  defp extract_npm_type_items(_, _package_key), do: []

  # Helper to get value from map with either string or atom keys
  defp get_value(map, key, default \\ nil)
  defp get_value(nil, _key, default), do: default

  defp get_value(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key)) || default
  end

  defp get_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp get_value(_, _, default), do: default

  defp truncate_doc(nil), do: ""
  defp truncate_doc(doc) when is_binary(doc), do: String.slice(doc, 0, 200)
  defp truncate_doc(_), do: ""

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
