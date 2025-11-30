defmodule Mimo.Library.Fetchers.NPMFetcher do
  @moduledoc """
  Fetches documentation from NPM for JavaScript/TypeScript packages.

  Uses the NPM registry API and unpkg.com to retrieve:
  - Package metadata and versions
  - README documentation
  - TypeScript type definitions
  - JSDoc documentation
  """

  require Logger

  @npm_registry "https://registry.npmjs.org"
  @unpkg_base "https://unpkg.com"
  @jsdelivr_base "https://cdn.jsdelivr.net/npm"

  @type package_info :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          readme: String.t() | nil,
          types: type_definitions() | nil,
          exports: [export_info()],
          dependencies: [String.t()]
        }

  @type type_definitions :: %{
          source: :bundled | :definitely_typed,
          content: String.t() | nil,
          modules: [type_module()]
        }

  @type type_module :: %{
          name: String.t(),
          exports: [type_export()]
        }

  @type type_export :: %{
          name: String.t(),
          kind: :function | :class | :interface | :type | :const,
          signature: String.t() | nil,
          doc: String.t() | nil
        }

  @type export_info :: %{
          name: String.t(),
          type: String.t() | nil,
          doc: String.t() | nil
        }

  @doc """
  Fetches documentation for an NPM package.

  ## Options
  - `:version` - Specific version to fetch (default: latest)
  - `:include_types` - Fetch TypeScript definitions (default: true)
  """
  @spec fetch(String.t(), keyword()) :: {:ok, package_info()} | {:error, term()}
  def fetch(package_name, opts \\ []) do
    version = Keyword.get(opts, :version)
    include_types = Keyword.get(opts, :include_types, true)

    with {:ok, metadata} <- fetch_package_metadata(package_name, version),
         resolved_version = metadata["version"],
         {:ok, types} <- maybe_fetch_types(package_name, resolved_version, metadata, include_types),
         {:ok, exports} <- extract_exports(package_name, resolved_version, metadata) do
      {:ok,
       %{
         name: package_name,
         version: resolved_version,
         description: metadata["description"] || "",
         readme: metadata["readme"],
         types: types,
         exports: exports,
         dependencies: extract_dependencies(metadata)
       }}
    end
  end

  @doc """
  Searches for packages matching a query.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    size = Keyword.get(opts, :size, 10)
    from = Keyword.get(opts, :from, 0)

    url = "#{@npm_registry}/-/v1/search?text=#{URI.encode(query)}&size=#{size}&from=#{from}"

    case http_get_json(url) do
      {:ok, %{"objects" => objects}} ->
        results =
          Enum.map(objects, fn obj ->
            pkg = obj["package"]

            %{
              name: pkg["name"],
              version: pkg["version"],
              description: pkg["description"],
              keywords: pkg["keywords"] || [],
              score: obj["score"]["final"],
              url: pkg["links"]["npm"]
            }
          end)

        {:ok, results}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Fetches TypeScript definitions for a package.
  """
  @spec fetch_types(String.t(), keyword()) :: {:ok, type_definitions()} | {:error, term()}
  def fetch_types(package_name, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_package_metadata(package_name, version) do
      resolved_version = metadata["version"]
      maybe_fetch_types(package_name, resolved_version, metadata, true)
    end
  end

  # Private functions

  defp fetch_package_metadata(package_name, nil) do
    # Handle scoped packages
    encoded_name = URI.encode(package_name, &(&1 != ?/))
    url = "#{@npm_registry}/#{encoded_name}/latest"

    case http_get_json(url) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, :not_found} ->
        # Try fetching the full package and getting latest
        url = "#{@npm_registry}/#{encoded_name}"

        case http_get_json(url) do
          {:ok, %{"dist-tags" => %{"latest" => latest_version}} = full} ->
            {:ok, get_in(full, ["versions", latest_version]) || full}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp fetch_package_metadata(package_name, version) do
    encoded_name = URI.encode(package_name, &(&1 != ?/))
    url = "#{@npm_registry}/#{encoded_name}/#{version}"
    http_get_json(url)
  end

  defp maybe_fetch_types(_package_name, _version, _metadata, false), do: {:ok, nil}

  defp maybe_fetch_types(package_name, version, metadata, true) do
    # Check if package has bundled types
    types_field = metadata["types"] || metadata["typings"]

    cond do
      types_field ->
        # Bundled TypeScript definitions
        fetch_bundled_types(package_name, version, types_field)

      has_definitely_typed?(package_name) ->
        # Try @types package
        fetch_definitely_typed(package_name)

      true ->
        {:ok, nil}
    end
  end

  defp fetch_bundled_types(package_name, version, types_path) do
    # Normalize the path
    types_path =
      if String.starts_with?(types_path, "./") do
        String.slice(types_path, 2..-1//1)
      else
        types_path
      end

    url = "#{@unpkg_base}/#{package_name}@#{version}/#{types_path}"

    case http_get_text(url) do
      {:ok, content} ->
        {:ok,
         %{
           source: :bundled,
           content: content,
           modules: parse_type_definitions(content)
         }}

      {:error, _} ->
        # Try jsdelivr as fallback
        url = "#{@jsdelivr_base}/#{package_name}@#{version}/#{types_path}"

        case http_get_text(url) do
          {:ok, content} ->
            {:ok,
             %{
               source: :bundled,
               content: content,
               modules: parse_type_definitions(content)
             }}

          _ ->
            {:ok, nil}
        end
    end
  end

  defp has_definitely_typed?(package_name) do
    # Check if @types package exists
    types_name = "@types/#{normalize_package_name(package_name)}"
    encoded = URI.encode(types_name, &(&1 != ?/))
    url = "#{@npm_registry}/#{encoded}"

    case Req.head(url) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  defp normalize_package_name(name) do
    # Handle scoped packages for DefinitelyTyped
    # @scope/package -> scope__package
    name
    |> String.replace(~r/^@/, "")
    |> String.replace("/", "__")
  end

  defp fetch_definitely_typed(package_name) do
    types_name = "@types/#{normalize_package_name(package_name)}"

    case fetch_package_metadata(types_name, nil) do
      {:ok, metadata} ->
        version = metadata["version"]
        types_path = metadata["types"] || metadata["typings"] || "index.d.ts"

        types_path =
          if String.starts_with?(types_path, "./") do
            String.slice(types_path, 2..-1//1)
          else
            types_path
          end

        url = "#{@unpkg_base}/#{types_name}@#{version}/#{types_path}"

        case http_get_text(url) do
          {:ok, content} ->
            {:ok,
             %{
               source: :definitely_typed,
               content: content,
               modules: parse_type_definitions(content)
             }}

          _ ->
            {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp parse_type_definitions(content) when is_binary(content) do
    # Parse TypeScript declaration file to extract exports
    modules = []

    # Extract exported interfaces
    interfaces =
      Regex.scan(~r/export\s+interface\s+(\w+)\s*(?:<[^>]+>)?\s*\{([^}]*)\}/s, content)
      |> Enum.map(fn [_, name, _body] ->
        %{
          name: name,
          kind: :interface,
          signature: nil,
          doc: extract_jsdoc_before(content, "interface #{name}")
        }
      end)

    # Extract exported types
    types =
      Regex.scan(~r/export\s+type\s+(\w+)\s*(?:<[^>]+>)?\s*=\s*([^;]+);/s, content)
      |> Enum.map(fn [_, name, definition] ->
        %{
          name: name,
          kind: :type,
          signature: String.trim(definition),
          doc: extract_jsdoc_before(content, "type #{name}")
        }
      end)

    # Extract exported functions
    functions =
      Regex.scan(
        ~r/export\s+(?:declare\s+)?function\s+(\w+)\s*(<[^>]*>)?\s*\(([^)]*)\)\s*:\s*([^;{]+)/s,
        content
      )
      |> Enum.map(fn
        [_, name, _generics, params, return_type] ->
          %{
            name: name,
            kind: :function,
            signature: "(#{String.trim(params)}) => #{String.trim(return_type)}",
            doc: extract_jsdoc_before(content, "function #{name}")
          }

        [_, name, params, return_type] ->
          %{
            name: name,
            kind: :function,
            signature: "(#{String.trim(params)}) => #{String.trim(return_type)}",
            doc: extract_jsdoc_before(content, "function #{name}")
          }
      end)

    # Extract exported classes
    classes =
      Regex.scan(
        ~r/export\s+(?:declare\s+)?class\s+(\w+)\s*(?:<[^>]+>)?\s*(?:extends\s+\w+)?\s*(?:implements\s+[^{]+)?\s*\{/s,
        content
      )
      |> Enum.map(fn [_, name | _] ->
        %{
          name: name,
          kind: :class,
          signature: nil,
          doc: extract_jsdoc_before(content, "class #{name}")
        }
      end)

    # Extract exported constants
    constants =
      Regex.scan(~r/export\s+(?:declare\s+)?const\s+(\w+)\s*:\s*([^;=]+)/s, content)
      |> Enum.map(fn [_, name, type_def] ->
        %{
          name: name,
          kind: :const,
          signature: String.trim(type_def),
          doc: extract_jsdoc_before(content, "const #{name}")
        }
      end)

    all_exports = interfaces ++ types ++ functions ++ classes ++ constants

    if Enum.empty?(all_exports) do
      modules
    else
      [%{name: "default", exports: all_exports}]
    end
  end

  defp extract_jsdoc_before(content, pattern) do
    # Try to find JSDoc comment before the pattern
    regex = ~r/\/\*\*\s*([\s\S]*?)\s*\*\/\s*(?:export\s+)?#{Regex.escape(pattern)}/

    case Regex.run(regex, content) do
      [_, doc] ->
        doc
        |> String.replace(~r/^\s*\*\s?/m, "")
        |> String.trim()

      _ ->
        nil
    end
  end

  defp extract_exports(package_name, version, metadata) do
    # Try to get main export information
    main_file = metadata["main"] || "index.js"

    # Try to fetch and parse the main file for exports
    url = "#{@unpkg_base}/#{package_name}@#{version}/#{main_file}"

    case http_get_text(url) do
      {:ok, content} ->
        exports = parse_js_exports(content)
        {:ok, exports}

      {:error, _} ->
        # Return basic info from package.json exports field
        case metadata["exports"] do
          exports when is_map(exports) ->
            parsed = parse_package_exports(exports)
            {:ok, parsed}

          _ ->
            {:ok, []}
        end
    end
  end

  defp parse_js_exports(content) do
    # Extract CommonJS exports
    cjs_exports =
      Regex.scan(~r/module\.exports\.(\w+)\s*=|exports\.(\w+)\s*=/s, content)
      |> Enum.flat_map(fn
        [_, name, ""] -> [name]
        [_, "", name] -> [name]
        _ -> []
      end)

    # Extract ES6 exports
    es6_exports =
      Regex.scan(~r/export\s+(?:const|let|var|function|class)\s+(\w+)/s, content)
      |> Enum.map(fn [_, name] -> name end)

    # Extract named exports
    named_exports =
      Regex.scan(~r/export\s*\{\s*([^}]+)\s*\}/s, content)
      |> Enum.flat_map(fn [_, names] ->
        names
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn name ->
          # Handle "name as alias"
          case String.split(name, " as ") do
            [original, _alias] -> String.trim(original)
            [name] -> name
          end
        end)
      end)

    (cjs_exports ++ es6_exports ++ named_exports)
    |> Enum.uniq()
    |> Enum.map(fn name ->
      %{name: name, type: nil, doc: nil}
    end)
  end

  defp parse_package_exports(exports) when is_map(exports) do
    exports
    |> Map.keys()
    |> Enum.map(fn key ->
      %{name: key, type: nil, doc: nil}
    end)
  end

  defp extract_dependencies(metadata) do
    deps = metadata["dependencies"] || %{}
    Map.keys(deps)
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

  defp http_get_text(url) do
    headers = [
      {"Accept", "text/plain, application/javascript, application/typescript"},
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
        Logger.warning("HTTP GET text failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
