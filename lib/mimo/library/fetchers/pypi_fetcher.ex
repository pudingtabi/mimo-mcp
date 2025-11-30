defmodule Mimo.Library.Fetchers.PyPIFetcher do
  @moduledoc """
  Fetches documentation from PyPI for Python packages.

  Uses the PyPI JSON API and ReadTheDocs to retrieve:
  - Package metadata and versions
  - Module documentation
  - Function signatures
  - Class documentation
  """

  require Logger

  @pypi_api_base "https://pypi.org/pypi"
  @readthedocs_base "https://readthedocs.org/api/v3"

  @type package_info :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          docs_url: String.t() | nil,
          modules: [module_doc()],
          dependencies: [String.t()]
        }

  @type module_doc :: %{
          name: String.t(),
          doc: String.t() | nil,
          classes: [class_doc()],
          functions: [function_doc()]
        }

  @type class_doc :: %{
          name: String.t(),
          doc: String.t() | nil,
          methods: [function_doc()]
        }

  @type function_doc :: %{
          name: String.t(),
          signature: String.t() | nil,
          doc: String.t() | nil
        }

  @doc """
  Fetches documentation for a PyPI package.

  ## Options
  - `:version` - Specific version to fetch (default: latest)
  """
  @spec fetch(String.t(), keyword()) :: {:ok, package_info()} | {:error, term()}
  def fetch(package_name, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_package_metadata(package_name, version),
         {:ok, docs_info} <- fetch_documentation(package_name, metadata) do
      {:ok,
       %{
         name: package_name,
         version: metadata["info"]["version"],
         description: metadata["info"]["summary"] || "",
         docs_url: get_docs_url(metadata),
         modules: docs_info,
         dependencies: extract_dependencies(metadata)
       }}
    end
  end

  @doc """
  Searches for packages matching a query.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)

    # PyPI search is via the simple HTML API or warehouse search
    # Using the JSON API with the search endpoint
    url = "https://pypi.org/search/?q=#{URI.encode(query)}&page=#{page}"

    case http_get_html(url) do
      {:ok, html} ->
        parse_search_results(html)

      error ->
        error
    end
  end

  # Private functions

  defp fetch_package_metadata(package_name, nil) do
    url = "#{@pypi_api_base}/#{package_name}/json"
    http_get_json(url)
  end

  defp fetch_package_metadata(package_name, version) do
    url = "#{@pypi_api_base}/#{package_name}/#{version}/json"
    http_get_json(url)
  end

  defp fetch_documentation(package_name, metadata) do
    # Try multiple documentation sources
    docs_url = get_docs_url(metadata)

    cond do
      docs_url && String.contains?(docs_url, "readthedocs") ->
        fetch_readthedocs(package_name, docs_url)

      docs_url ->
        fetch_generic_docs(docs_url)

      true ->
        # Fallback: try common ReadTheDocs URL patterns
        fetch_readthedocs_fallback(package_name)
    end
  end

  defp get_docs_url(metadata) do
    info = metadata["info"] || %{}

    # Check various documentation URL fields
    info["docs_url"] ||
      info["documentation_url"] ||
      get_in(info, ["project_urls", "Documentation"]) ||
      get_in(info, ["project_urls", "Docs"]) ||
      get_in(info, ["project_urls", "documentation"])
  end

  defp fetch_readthedocs(_package_name, docs_url) do
    # Extract project slug from URL
    case Regex.run(~r/https?:\/\/([^\.]+)\.readthedocs/, docs_url) do
      [_, slug] ->
        # Fetch API index
        api_url = "#{@readthedocs_base}/projects/#{slug}/"

        case http_get_json(api_url) do
          {:ok, project_info} ->
            fetch_rtd_modules(slug, project_info)

          {:error, _} ->
            # Fallback to scraping the docs site
            scrape_documentation_site(docs_url)
        end

      _ ->
        scrape_documentation_site(docs_url)
    end
  end

  defp fetch_rtd_modules(slug, _project_info) do
    # Fetch the objects.inv file which contains documentation inventory
    inv_url = "https://#{slug}.readthedocs.io/en/latest/objects.inv"

    case http_get_binary(inv_url) do
      {:ok, data} ->
        parse_sphinx_inventory(data)

      {:error, _} ->
        # Fallback to parsing the HTML index
        index_url = "https://#{slug}.readthedocs.io/en/latest/py-modindex.html"

        case http_get_html(index_url) do
          {:ok, html} -> parse_module_index(html)
          error -> error
        end
    end
  end

  defp fetch_readthedocs_fallback(package_name) do
    # Try common URL patterns
    normalized_name = String.replace(package_name, "_", "-")

    urls = [
      "https://#{normalized_name}.readthedocs.io/en/latest/",
      "https://#{package_name}.readthedocs.io/en/latest/",
      "https://python-#{normalized_name}.readthedocs.io/en/latest/"
    ]

    Enum.find_value(urls, {:ok, []}, fn url ->
      case scrape_documentation_site(url) do
        {:ok, modules} when modules != [] -> {:ok, modules}
        _ -> nil
      end
    end)
  end

  defp fetch_generic_docs(docs_url) do
    scrape_documentation_site(docs_url)
  end

  defp scrape_documentation_site(base_url) do
    case http_get_html(base_url) do
      {:ok, html} ->
        modules = parse_generic_docs(html, base_url)
        {:ok, modules}

      error ->
        error
    end
  end

  defp parse_search_results(html) do
    # Parse PyPI search results HTML
    results =
      Regex.scan(
        ~r/<a class="package-snippet"[^>]*href="([^"]+)"[^>]*>.*?<span class="package-snippet__name">([^<]+)<\/span>.*?<span class="package-snippet__version">([^<]+)<\/span>.*?<p class="package-snippet__description">([^<]*)<\/p>/s,
        html
      )
      |> Enum.map(fn [_, url, name, version, description] ->
        %{
          name: String.trim(name),
          version: String.trim(version),
          description: String.trim(description),
          url: "https://pypi.org" <> url
        }
      end)

    {:ok, results}
  rescue
    _ -> {:ok, []}
  end

  defp parse_sphinx_inventory(data) do
    # Sphinx objects.inv format:
    # First 4 lines are header, rest is zlib-compressed
    lines = String.split(data, "\n", parts: 5)

    case lines do
      [_, _, _, _, compressed] when byte_size(compressed) > 0 ->
        case decompress_inventory(compressed) do
          {:ok, text} -> parse_inventory_text(text)
          _ -> {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  defp decompress_inventory(compressed) do
    try do
      decompressed = :zlib.uncompress(compressed)
      {:ok, decompressed}
    rescue
      _ -> {:error, :decompression_failed}
    end
  end

  defp parse_inventory_text(text) do
    modules =
      String.split(text, "\n")
      |> Enum.filter(fn line ->
        String.contains?(line, "py:module") || String.contains?(line, "py:class")
      end)
      |> Enum.map(fn line ->
        # Format: name domain:role priority uri dispname
        parts = String.split(line, " ", parts: 5)

        case parts do
          [name | _] -> %{name: name, doc: nil, classes: [], functions: []}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.name)

    {:ok, modules}
  end

  defp parse_module_index(html) do
    # Parse Sphinx py-modindex.html
    modules =
      Regex.scan(~r/<a[^>]*href="([^"]+)"[^>]*><code[^>]*>([^<]+)<\/code><\/a>/s, html)
      |> Enum.map(fn [_, _url, name] ->
        %{name: String.trim(name), doc: nil, classes: [], functions: []}
      end)

    {:ok, modules}
  end

  defp parse_generic_docs(html, _base_url) do
    # Generic documentation parsing - look for common patterns
    # Try to find module-like structures
    modules =
      Regex.scan(~r/<h[12][^>]*>(?:Module|Class|API)?\s*:?\s*<code>([^<]+)<\/code>/s, html)
      |> Enum.map(fn [_, name] ->
        %{name: String.trim(name), doc: nil, classes: [], functions: []}
      end)

    if Enum.empty?(modules) do
      # Try alternative patterns
      Regex.scan(~r/<dt[^>]*id="([^"]+)"[^>]*>/s, html)
      # Limit results
      |> Enum.take(50)
      |> Enum.map(fn [_, id] ->
        %{name: id, doc: nil, classes: [], functions: []}
      end)
    else
      modules
    end
  end

  defp extract_dependencies(metadata) do
    requires_dist = metadata["info"]["requires_dist"] || []

    requires_dist
    |> Enum.map(fn dep ->
      # Parse dependency string like "requests (>=2.25.0)"
      case Regex.run(~r/^([a-zA-Z0-9_-]+)/, dep) do
        [_, name] -> name
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # HTTP helpers

  defp http_get_json(url) do
    headers = [
      {"Accept", "application/json"},
      {"User-Agent", "Mimo/1.0"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :json_parse_error}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("HTTP GET JSON failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp http_get_html(url) do
    headers = [
      {"Accept", "text/html"},
      {"User-Agent", "Mimo/1.0"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("HTTP GET HTML failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp http_get_binary(url) do
    headers = [
      {"Accept", "*/*"},
      {"User-Agent", "Mimo/1.0"}
    ]

    case Req.get(url, headers: headers, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
