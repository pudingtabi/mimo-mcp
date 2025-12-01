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
    # Try to fetch from search.html first (contains searchData JSON)
    search_url = "#{@hexdocs_base}/#{package_name}/#{version}/search.html"

    case fetch_search_data(search_url) do
      {:ok, modules} when modules != [] ->
        filter_modules(modules, opts)

      _ ->
        # Fallback: parse api-reference.html
        docs_url = "#{@hexdocs_base}/#{package_name}/#{version}/api-reference.html"

        case fetch_api_reference(docs_url) do
          {:ok, modules} -> filter_modules(modules, opts)
          error -> error
        end
    end
  end

  defp fetch_api_reference(url) do
    case http_get_html(url) do
      {:ok, html} ->
        parse_api_reference_with_floki(html)

      error ->
        error
    end
  end

  defp parse_api_reference_with_floki(html) do
    # Use Floki to parse the HTML properly
    case Floki.parse_document(html) do
      {:ok, document} ->
        # Find all module entries in the summary rows
        # New HexDocs structure: <div class="summary-row">...<a href="Module.html">Module</a>...</div>
        modules =
          document
          |> Floki.find("div.summary-row")
          |> Enum.map(fn row ->
            # Get the module name from the link
            link = Floki.find(row, "div.summary-signature a")
            synopsis = Floki.find(row, "div.summary-synopsis")

            case link do
              [{_, _, [name | _]} | _] ->
                name_text = extract_text(name)
                doc_text = extract_text(synopsis)

                %{
                  "name" => String.trim(name_text),
                  "doc" => if(doc_text != "", do: String.trim(doc_text), else: nil),
                  "functions" => [],
                  "types" => []
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          # Filter out Mix Tasks section - we only want modules
          |> Enum.filter(fn mod ->
            name = mod["name"]
            # Keep if it looks like a module name (starts with capital letter)
            String.match?(name, ~r/^[A-Z]/)
          end)

        {:ok, modules}

      {:error, reason} ->
        Logger.warning("Failed to parse API reference HTML: #{inspect(reason)}")
        {:error, :parse_error}
    end
  rescue
    e ->
      Logger.warning("Exception parsing API reference: #{inspect(e)}")
      {:error, :parse_error}
  end

  defp extract_text(elements) when is_list(elements) do
    elements
    |> Floki.text()
    |> String.trim()
  end

  defp extract_text(element) when is_tuple(element) do
    element
    |> Floki.text()
    |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: String.trim(text)
  defp extract_text(_), do: ""

  defp fetch_search_data(url) do
    case http_get_html(url) do
      {:ok, html} ->
        # Try to extract searchNodes or searchData from the script
        # ExDoc uses different variable names in different versions
        patterns = [
          ~r/searchNodes\s*=\s*(\[[\s\S]*?\]);?\s*(?:var|const|let|<\/script>)/,
          ~r/searchData\s*=\s*(\[[\s\S]*?\]);?\s*(?:var|const|let|<\/script>)/,
          ~r/"items"\s*:\s*(\[[\s\S]*?\])\s*\}/
        ]

        result =
          Enum.find_value(patterns, fn pattern ->
            case Regex.run(pattern, html) do
              [_, json] ->
                # Clean up the JSON - remove trailing semicolons and whitespace
                clean_json =
                  json
                  |> String.trim()
                  |> String.trim_trailing(";")

                case Jason.decode(clean_json) do
                  {:ok, data} when is_list(data) -> {:ok, data}
                  _ -> nil
                end

              _ ->
                nil
            end
          end)

        case result do
          {:ok, data} -> parse_search_data(data)
          nil -> {:ok, []}
        end

      error ->
        error
    end
  end

  defp parse_search_data(data) when is_list(data) do
    modules =
      data
      |> Enum.filter(fn item ->
        # ExDoc marks modules with type "module" or just uppercase names
        item["type"] == "module" ||
          (is_nil(item["type"]) && String.match?(item["title"] || "", ~r/^[A-Z]/))
      end)
      |> Enum.map(fn item ->
        %{
          "name" => item["title"] || item["ref"],
          "doc" => item["doc"],
          "functions" => [],
          "types" => []
        }
      end)
      |> Enum.uniq_by(& &1["name"])

    {:ok, modules}
  end

  defp parse_search_data(_), do: {:ok, []}

  defp fetch_module_docs(package_name, version, module_name) do
    # Convert module name to URL path (e.g., "Ecto.Query" -> "Ecto.Query.html")
    module_path = "#{module_name}.html"
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
    case Floki.parse_document(html) do
      {:ok, document} ->
        # Extract module documentation
        module_doc = extract_module_doc_floki(document)
        functions = extract_functions_floki(document)
        types = extract_types_floki(document)

        {:ok,
         %{
           name: module_name,
           doc: module_doc,
           functions: functions,
           types: types
         }}

      {:error, _} ->
        {:error, :parse_error}
    end
  end

  defp extract_module_doc_floki(document) do
    document
    |> Floki.find("section.moduledoc")
    |> Floki.text()
    |> String.trim()
    |> case do
      "" -> nil
      doc -> doc
    end
  end

  defp extract_functions_floki(document) do
    document
    |> Floki.find("section.detail[id]")
    |> Enum.filter(fn section ->
      {_, attrs, _} = section
      id = Enum.find_value(attrs, fn {k, v} -> if k == "id", do: v end)
      # Functions have ids like "function_name/2", not "t:type_name/0"
      id && !String.starts_with?(id, "t:")
    end)
    |> Enum.map(fn section ->
      {_, attrs, _} = section
      id = Enum.find_value(attrs, fn {k, v} -> if k == "id", do: v end)
      {name, arity} = parse_function_id(id || "unknown/0")

      doc =
        section
        |> Floki.find("section.docstring")
        |> Floki.text()
        |> String.trim()

      %{
        name: name,
        arity: arity,
        doc: if(doc == "", do: nil, else: doc),
        spec: nil
      }
    end)
  end

  defp extract_types_floki(document) do
    document
    |> Floki.find("section.detail[id^=\"t:\"]")
    |> Enum.map(fn section ->
      {_, attrs, _} = section
      id = Enum.find_value(attrs, fn {k, v} -> if k == "id", do: v end)
      # Remove "t:" prefix
      type_id = String.replace(id || "unknown", "t:", "")

      definition =
        section
        |> Floki.find("h1")
        |> Floki.text()
        |> String.trim()

      %{
        name: type_id,
        doc: nil,
        definition: definition
      }
    end)
  end

  defp parse_function_id(id) do
    case Regex.run(~r/^([^\/]+)\/(\d+)$/, id) do
      [_, name, arity] -> {name, String.to_integer(arity)}
      _ -> {id, 0}
    end
  end

  defp filter_modules(modules, opts) do
    case Keyword.get(opts, :modules) do
      nil ->
        {:ok, modules}

      filter_list ->
        filtered = Enum.filter(modules, fn m -> m["name"] in filter_list end)
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

  # HTTP helpers - delegate to Common module with retry logic

  alias Mimo.Library.Fetchers.Common

  defp http_get(url) do
    case Common.http_get_json(url) do
      {:ok, body} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  defp http_get_html(url) do
    Common.http_get_html(url)
  end
end
