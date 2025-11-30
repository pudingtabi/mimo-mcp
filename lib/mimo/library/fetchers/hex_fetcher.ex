defmodule Mimo.Library.Fetchers.HexFetcher do
  @moduledoc """
  Fetches documentation from Hex.pm for Elixir/Erlang packages.

  Uses the Hex.pm API to retrieve:
  - Package metadata and versions
  - Module documentation
  - Function specs and docs
  - Type specifications
  """

  require Logger

  @hex_api_base "https://hex.pm/api"
  @hexdocs_base "https://hexdocs.pm"

  @type package_info :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          docs_url: String.t(),
          modules: [module_doc()],
          dependencies: [String.t()]
        }

  @type module_doc :: %{
          name: String.t(),
          doc: String.t() | nil,
          functions: [function_doc()],
          types: [type_doc()]
        }

  @type function_doc :: %{
          name: String.t(),
          arity: non_neg_integer(),
          doc: String.t() | nil,
          spec: String.t() | nil
        }

  @type type_doc :: %{
          name: String.t(),
          doc: String.t() | nil,
          definition: String.t()
        }

  @doc """
  Fetches documentation for a Hex package.

  ## Options
  - `:version` - Specific version to fetch (default: latest)
  - `:modules` - List of specific modules to fetch docs for
  - `:include_private` - Include private functions (default: false)
  """
  @spec fetch(String.t(), keyword()) :: {:ok, package_info()} | {:error, term()}
  def fetch(package_name, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_package_metadata(package_name),
         {:ok, resolved_version} <- resolve_version(metadata, version),
         {:ok, docs} <- fetch_docs(package_name, resolved_version, opts) do
      {:ok,
       %{
         name: package_name,
         version: resolved_version,
         description: metadata["meta"]["description"] || "",
         docs_url: "#{@hexdocs_base}/#{package_name}/#{resolved_version}",
         modules: docs,
         dependencies: extract_dependencies(metadata, resolved_version)
       }}
    end
  end

  @doc """
  Searches for packages matching a query.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 10)

    url = "#{@hex_api_base}/packages?search=#{URI.encode(query)}&page=#{page}&per_page=#{per_page}"

    case http_get(url) do
      {:ok, packages} when is_list(packages) ->
        results =
          Enum.map(packages, fn pkg ->
            %{
              name: pkg["name"],
              description: pkg["meta"]["description"],
              latest_version: get_in(pkg, ["releases", Access.at(0), "version"]),
              downloads: pkg["downloads"]["all"] || 0,
              url: pkg["html_url"]
            }
          end)

        {:ok, results}

      {:ok, _} ->
        {:error, :invalid_response}

      error ->
        error
    end
  end

  @doc """
  Fetches documentation for a specific module in a package.
  """
  @spec fetch_module(String.t(), String.t(), keyword()) :: {:ok, module_doc()} | {:error, term()}
  def fetch_module(package_name, module_name, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_package_metadata(package_name),
         {:ok, resolved_version} <- resolve_version(metadata, version) do
      fetch_module_docs(package_name, resolved_version, module_name)
    end
  end

  # Private functions

  defp fetch_package_metadata(package_name) do
    url = "#{@hex_api_base}/packages/#{package_name}"

    case http_get(url) do
      {:ok, %{"name" => _} = metadata} ->
        {:ok, metadata}

      {:ok, %{"status" => 404}} ->
        {:error, :package_not_found}

      {:ok, _} ->
        {:error, :invalid_response}

      error ->
        error
    end
  end

  defp resolve_version(metadata, nil) do
    # Get latest stable version
    case metadata["releases"] do
      [%{"version" => version} | _] -> {:ok, version}
      _ -> {:error, :no_versions}
    end
  end

  defp resolve_version(metadata, version) do
    versions = Enum.map(metadata["releases"] || [], & &1["version"])

    if version in versions do
      {:ok, version}
    else
      {:error, {:version_not_found, version}}
    end
  end

  defp fetch_docs(package_name, version, opts) do
    # Try to fetch the docs tarball
    docs_url = "#{@hexdocs_base}/#{package_name}/#{version}/api-reference.html"

    case fetch_api_reference(docs_url) do
      {:ok, modules} ->
        filter_modules(modules, opts)

      {:error, _} ->
        # Fallback: try to parse from search.html
        search_url = "#{@hexdocs_base}/#{package_name}/#{version}/search.html"

        case fetch_search_data(search_url) do
          {:ok, modules} -> filter_modules(modules, opts)
          error -> error
        end
    end
  end

  defp fetch_api_reference(url) do
    case http_get_html(url) do
      {:ok, html} ->
        parse_api_reference(html)

      error ->
        error
    end
  end

  defp parse_api_reference(html) do
    # Parse the API reference HTML to extract module information
    # This is a simplified parser - in production, use a proper HTML parser
    modules =
      Regex.scan(
        ~r/<li[^>]*class="[^"]*module[^"]*"[^>]*>.*?<a[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/s,
        html
      )
      |> Enum.map(fn [_, href, name] ->
        %{
          name: String.trim(name),
          doc: nil,
          functions: [],
          types: [],
          url: href
        }
      end)

    {:ok, modules}
  rescue
    _ -> {:error, :parse_error}
  end

  defp fetch_search_data(url) do
    case http_get_html(url) do
      {:ok, html} ->
        # Extract search data JSON from the page
        case Regex.run(~r/searchData\s*=\s*(\[.*?\]);/s, html) do
          [_, json] ->
            case Jason.decode(json) do
              {:ok, data} -> parse_search_data(data)
              _ -> {:error, :json_parse_error}
            end

          _ ->
            # No search data found
            {:ok, []}
        end

      error ->
        error
    end
  end

  defp parse_search_data(data) when is_list(data) do
    modules =
      data
      |> Enum.filter(fn item -> item["type"] == "module" end)
      |> Enum.map(fn item ->
        %{
          name: item["title"],
          doc: item["doc"],
          functions: [],
          types: []
        }
      end)

    {:ok, modules}
  end

  defp parse_search_data(_), do: {:ok, []}

  defp fetch_module_docs(package_name, version, module_name) do
    # Convert module name to URL path (e.g., "Ecto.Query" -> "Ecto.Query.html")
    module_path = String.replace(module_name, ".", "/") <> ".html"
    url = "#{@hexdocs_base}/#{package_name}/#{version}/#{module_path}"

    case http_get_html(url) do
      {:ok, html} ->
        parse_module_page(html, module_name)

      {:error, :not_found} ->
        {:error, {:module_not_found, module_name}}

      error ->
        error
    end
  end

  defp parse_module_page(html, module_name) do
    # Extract module documentation
    module_doc = extract_module_doc(html)
    functions = extract_functions(html)
    types = extract_types(html)

    {:ok,
     %{
       name: module_name,
       doc: module_doc,
       functions: functions,
       types: types
     }}
  end

  defp extract_module_doc(html) do
    case Regex.run(~r/<section[^>]*class="[^"]*moduledoc[^"]*"[^>]*>(.*?)<\/section>/s, html) do
      [_, doc] -> strip_html_tags(doc) |> String.trim()
      _ -> nil
    end
  end

  defp extract_functions(html) do
    # Extract function signatures and docs
    Regex.scan(
      ~r/<section[^>]*class="[^"]*detail[^"]*"[^>]*id="([^"]+)"[^>]*>.*?<h1[^>]*>(.*?)<\/h1>.*?<section[^>]*class="[^"]*docstring[^"]*"[^>]*>(.*?)<\/section>/s,
      html
    )
    |> Enum.map(fn [_, id, signature, doc] ->
      {name, arity} = parse_function_id(id)

      %{
        name: name,
        arity: arity,
        doc: strip_html_tags(doc) |> String.trim(),
        spec: extract_spec(signature)
      }
    end)
  end

  defp extract_types(html) do
    Regex.scan(
      ~r/<section[^>]*class="[^"]*detail[^"]*"[^>]*id="t:([^"]+)"[^>]*>.*?<h1[^>]*>(.*?)<\/h1>/s,
      html
    )
    |> Enum.map(fn [_, id, definition] ->
      %{
        name: id,
        doc: nil,
        definition: strip_html_tags(definition) |> String.trim()
      }
    end)
  end

  defp parse_function_id(id) do
    case Regex.run(~r/^([^\/]+)\/(\d+)$/, id) do
      [_, name, arity] -> {name, String.to_integer(arity)}
      _ -> {id, 0}
    end
  end

  defp extract_spec(signature) do
    # Try to extract @spec from the signature
    case Regex.run(~r/@spec\s+(.+)/, signature) do
      [_, spec] -> String.trim(spec)
      _ -> nil
    end
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp filter_modules(modules, opts) do
    case Keyword.get(opts, :modules) do
      nil ->
        {:ok, modules}

      filter_list ->
        filtered = Enum.filter(modules, fn m -> m.name in filter_list end)
        {:ok, filtered}
    end
  end

  defp extract_dependencies(metadata, version) do
    release = Enum.find(metadata["releases"] || [], fn r -> r["version"] == version end)

    case release do
      %{"requirements" => reqs} when is_map(reqs) ->
        Map.keys(reqs)

      _ ->
        []
    end
  end

  # HTTP helpers

  defp http_get(url) do
    headers = [
      {"Accept", "application/json"},
      {"User-Agent", "Mimo/1.0"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("HTTP GET failed for #{url}: #{inspect(reason)}")
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
end
