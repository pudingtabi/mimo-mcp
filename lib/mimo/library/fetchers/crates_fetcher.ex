defmodule Mimo.Library.Fetchers.CratesFetcher do
  @moduledoc """
  Fetches documentation from crates.io and docs.rs for Rust packages.

  Uses the crates.io API and docs.rs to retrieve:
  - Crate metadata and versions
  - Module documentation from docs.rs
  - Struct, trait, and function documentation
  """

  require Logger

  alias Mimo.Library.Fetchers.Common

  @crates_api "https://crates.io/api/v1"
  @docs_rs_base "https://docs.rs"

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
          path: String.t(),
          doc: String.t() | nil,
          items: [item_doc()]
        }

  @type item_doc :: %{
          name: String.t(),
          kind: :struct | :enum | :trait | :function | :type | :const | :macro,
          signature: String.t() | nil,
          doc: String.t() | nil
        }

  @doc """
  Fetches documentation for a Rust crate.

  ## Options
  - `:version` - Specific version to fetch (default: latest)
  """
  @spec fetch(String.t(), keyword()) :: {:ok, package_info()} | {:error, term()}
  def fetch(crate_name, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_crate_metadata(crate_name),
         {:ok, resolved_version} <- resolve_version(metadata, version),
         {:ok, docs} <- fetch_docs_rs(crate_name, resolved_version) do
      {:ok,
       %{
         name: crate_name,
         version: resolved_version,
         description: metadata["crate"]["description"] || "",
         docs_url: "#{@docs_rs_base}/#{crate_name}/#{resolved_version}",
         modules: docs,
         dependencies: extract_dependencies(metadata, resolved_version)
       }}
    end
  end

  @doc """
  Searches for crates matching a query.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 10)

    url = "#{@crates_api}/crates?q=#{URI.encode(query)}&page=#{page}&per_page=#{per_page}"

    case http_get_json(url) do
      {:ok, %{"crates" => crates}} ->
        results =
          Enum.map(crates, fn crate ->
            %{
              name: crate["name"],
              version: crate["max_version"],
              description: crate["description"],
              downloads: crate["downloads"],
              url: "https://crates.io/crates/#{crate["name"]}"
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
  Fetches documentation for a specific module in a crate.
  """
  @spec fetch_module(String.t(), String.t(), keyword()) :: {:ok, module_doc()} | {:error, term()}
  def fetch_module(crate_name, module_path, opts \\ []) do
    version = Keyword.get(opts, :version)

    with {:ok, metadata} <- fetch_crate_metadata(crate_name),
         {:ok, resolved_version} <- resolve_version(metadata, version) do
      fetch_module_docs(crate_name, resolved_version, module_path)
    end
  end

  # Private functions

  defp fetch_crate_metadata(crate_name) do
    url = "#{@crates_api}/crates/#{crate_name}"

    case http_get_json(url) do
      {:ok, %{"crate" => _} = metadata} ->
        {:ok, metadata}

      {:ok, %{"errors" => _}} ->
        {:error, :crate_not_found}

      error ->
        error
    end
  end

  defp resolve_version(metadata, nil) do
    # Get latest version
    case metadata["crate"]["max_version"] do
      nil -> {:error, :no_versions}
      version -> {:ok, version}
    end
  end

  defp resolve_version(metadata, version) do
    versions = Enum.map(metadata["versions"] || [], & &1["num"])

    if version in versions do
      {:ok, version}
    else
      {:error, {:version_not_found, version}}
    end
  end

  defp fetch_docs_rs(crate_name, version) do
    # Fetch the main documentation page
    url = "#{@docs_rs_base}/#{crate_name}/#{version}/#{crate_name}/"

    case http_get_html(url) do
      {:ok, html} ->
        parse_docs_rs_index(html, crate_name, version)

      {:error, :not_found} ->
        # Try alternative URL pattern (with underscores)
        normalized = String.replace(crate_name, "-", "_")
        url = "#{@docs_rs_base}/#{crate_name}/#{version}/#{normalized}/"

        case http_get_html(url) do
          {:ok, html} -> parse_docs_rs_index(html, crate_name, version)
          error -> error
        end

      error ->
        error
    end
  end

  defp parse_docs_rs_index(html, crate_name, _version) do
    # Extract module list from the sidebar
    modules =
      Regex.scan(
        ~r/<a[^>]*class="[^"]*mod[^"]*"[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/s,
        html
      )
      |> Enum.map(fn [_, href, name] ->
        %{
          name: String.trim(name),
          path: href,
          doc: nil,
          items: []
        }
      end)

    # Extract items from the current module
    items = parse_module_items(html)

    # Create the main module
    main_module = %{
      name: crate_name,
      path: "/",
      doc: extract_crate_doc(html),
      items: items
    }

    {:ok, [main_module | modules]}
  end

  defp parse_module_items(html) do
    structs = extract_items(html, "struct", :struct)
    enums = extract_items(html, "enum", :enum)
    traits = extract_items(html, "trait", :trait)
    functions = extract_items(html, "fn", :function)
    types = extract_items(html, "type", :type)
    constants = extract_items(html, "constant", :const)
    macros = extract_items(html, "macro", :macro)

    structs ++ enums ++ traits ++ functions ++ types ++ constants ++ macros
  end

  defp extract_items(html, css_class, kind) do
    Regex.scan(
      ~r/<div[^>]*class="[^"]*item-name[^"]*"[^>]*>.*?<a[^>]*class="[^"]*#{css_class}[^"]*"[^>]*>([^<]+)<\/a>.*?<\/div>\s*<div[^>]*class="[^"]*desc[^"]*"[^>]*>(.*?)<\/div>/s,
      html
    )
    |> Enum.map(fn [_, name, doc] ->
      %{
        name: String.trim(name),
        kind: kind,
        signature: nil,
        doc: strip_html_tags(doc) |> String.trim()
      }
    end)
  end

  defp extract_crate_doc(html) do
    case Regex.run(
           ~r/<section[^>]*id="main-content"[^>]*>.*?<details[^>]*class="[^"]*top-doc[^"]*"[^>]*>.*?<div[^>]*class="[^"]*docblock[^"]*"[^>]*>(.*?)<\/div>/s,
           html
         ) do
      [_, doc] -> strip_html_tags(doc) |> String.trim()
      _ -> nil
    end
  end

  defp fetch_module_docs(crate_name, version, module_path) do
    # Convert module path to URL
    # e.g., "serde::de" -> "serde/de/index.html"
    url_path =
      module_path
      |> String.replace("::", "/")
      |> then(&"#{@docs_rs_base}/#{crate_name}/#{version}/#{crate_name}/#{&1}/index.html")

    case http_get_html(url_path) do
      {:ok, html} ->
        items = parse_module_items(html)
        doc = extract_module_doc(html)

        {:ok,
         %{
           name: module_path,
           path: url_path,
           doc: doc,
           items: items
         }}

      {:error, :not_found} ->
        {:error, {:module_not_found, module_path}}

      error ->
        error
    end
  end

  defp extract_module_doc(html) do
    case Regex.run(
           ~r/<section[^>]*id="main-content"[^>]*>.*?<div[^>]*class="[^"]*docblock[^"]*"[^>]*>(.*?)<\/div>/s,
           html
         ) do
      [_, doc] -> strip_html_tags(doc) |> String.trim()
      _ -> nil
    end
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp extract_dependencies(metadata, version) do
    # Find the specific version
    version_info = Enum.find(metadata["versions"] || [], fn v -> v["num"] == version end)

    case version_info do
      %{"id" => version_id} ->
        # Fetch dependencies for this version
        url = "#{@crates_api}/crates/#{metadata["crate"]["name"]}/#{version_id}/dependencies"

        case http_get_json(url) do
          {:ok, %{"dependencies" => deps}} ->
            deps
            |> Enum.filter(fn d -> d["kind"] == "normal" end)
            |> Enum.map(& &1["crate_id"])

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # HTTP helpers - delegate to Common with retry logic

  defp http_get_json(url), do: Common.http_get_json(url)
  defp http_get_html(url), do: Common.http_get_html(url)
end
