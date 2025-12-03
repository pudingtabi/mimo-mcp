defmodule Mimo.Tools.Dispatchers.Code do
  @moduledoc """
  Unified Code Intelligence dispatcher.

  Consolidates code analysis, package documentation, and diagnostics:

  ## Code Symbols Operations (from code_symbols tool)
  - parse: Parse file or source code
  - symbols: List symbols in file/directory
  - references: Find all references
  - search: Search symbols by pattern
  - definition: Find symbol definition
  - call_graph: Get callers and callees
  - index: Index file/directory

  ## Library Operations (from library tool)
  - library: Fetch package info (alias for library_get)
  - library_get: Fetch package info
  - library_search: Search packages
  - library_ensure: Ensure package is cached
  - library_discover: Auto-discover and cache deps
  - library_stats: Cache statistics

  ## Diagnostics Operations (from diagnostics tool)
  - check: Compiler errors
  - lint: Linter warnings
  - typecheck: Type checker
  - diagnose: Run all diagnostics (alias for diagnostics_all)
  - diagnostics_all: Run all diagnostics

  Supports: Elixir, Python, JavaScript, TypeScript, TSX, Rust, Go
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch code operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "symbols"

    case op do
      # === Code Symbols Operations ===
      "parse" ->
        dispatch_parse(args)

      "symbols" ->
        dispatch_symbols(args)

      "references" ->
        dispatch_references(args)

      "search" ->
        dispatch_search(args)

      "definition" ->
        dispatch_definition(args)

      "call_graph" ->
        dispatch_call_graph(args)

      "index" ->
        dispatch_index(args)

      # === Library Operations ===
      "library" ->
        # Shorthand: code operation=library name="..." → get package
        dispatch_library_get(args)

      "library_get" ->
        dispatch_library_get(args)

      "library_search" ->
        dispatch_library_search(args)

      "library_ensure" ->
        dispatch_library_ensure(args)

      "library_discover" ->
        dispatch_library_discover(args)

      "library_stats" ->
        {:ok, Mimo.Library.CacheManager.stats()}

      # === Diagnostics Operations ===
      "check" ->
        dispatch_diagnostics(args, :check)

      "lint" ->
        dispatch_diagnostics(args, :lint)

      "typecheck" ->
        dispatch_diagnostics(args, :typecheck)

      "diagnose" ->
        # Alias for diagnostics_all
        dispatch_diagnostics(args, :all)

      "diagnostics_all" ->
        dispatch_diagnostics(args, :all)

      _ ->
        {:error,
         "Unknown code operation: #{op}. Valid operations: " <>
           "symbols, parse, references, search, definition, call_graph, index, " <>
           "library, library_get, library_search, library_ensure, library_discover, library_stats, " <>
           "check, lint, typecheck, diagnose, diagnostics_all"}
    end
  end

  # ==========================================================================
  # CODE SYMBOLS OPERATIONS
  # ==========================================================================

  defp dispatch_parse(args) do
    cond do
      args["path"] ->
        case Mimo.Code.TreeSitter.parse_file(args["path"]) do
          {:ok, tree} ->
            case Mimo.Code.TreeSitter.get_sexp(tree) do
              {:ok, sexp} -> {:ok, %{parsed: true, sexp: String.slice(sexp, 0, 2000)}}
              error -> error
            end

          error ->
            error
        end

      args["source"] && args["language"] ->
        case Mimo.Code.TreeSitter.parse(args["source"], args["language"]) do
          {:ok, tree} ->
            {:ok, symbols} = Mimo.Code.TreeSitter.get_symbols(tree)
            {:ok, refs} = Mimo.Code.TreeSitter.get_references(tree)
            {:ok, %{parsed: true, symbols: symbols, references: refs}}

          error ->
            error
        end

      true ->
        {:error, "Either path or source+language is required"}
    end
  end

  defp dispatch_symbols(args) do
    cond do
      args["path"] && File.dir?(args["path"]) ->
        # List symbols in directory
        case Mimo.Code.SymbolIndex.index_directory(args["path"]) do
          {:ok, _} ->
            stats = Mimo.Code.SymbolIndex.stats()
            {:ok, stats}

          error ->
            error
        end

      args["path"] ->
        # List symbols in file
        symbols = Mimo.Code.SymbolIndex.symbols_in_file(args["path"])

        {:ok,
         %{
           file: args["path"],
           symbols: Enum.map(symbols, &Helpers.format_symbol/1),
           count: length(symbols)
         }}

      true ->
        # Return index stats
        {:ok, Mimo.Code.SymbolIndex.stats()}
    end
  end

  defp dispatch_references(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required for references lookup"}
    else
      refs = Mimo.Code.SymbolIndex.find_references(name, limit: args["limit"] || 50)

      {:ok,
       %{
         symbol: name,
         references: Enum.map(refs, &Helpers.format_reference/1),
         count: length(refs)
       }}
    end
  end

  defp dispatch_search(args) do
    pattern = args["pattern"] || args["name"] || ""

    if pattern == "" do
      {:error, "Search pattern is required"}
    else
      opts = []
      opts = if args["kind"], do: Keyword.put(opts, :kind, args["kind"]), else: opts
      opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

      symbols = Mimo.Code.SymbolIndex.search(pattern, opts)

      {:ok,
       %{
         pattern: pattern,
         symbols: Enum.map(symbols, &Helpers.format_symbol/1),
         count: length(symbols)
       }}
    end
  end

  defp dispatch_definition(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required"}
    else
      case Mimo.Code.SymbolIndex.find_definition(name) do
        nil ->
          {:ok, %{symbol: name, found: false}}

        symbol ->
          {:ok, %{symbol: name, found: true, definition: Helpers.format_symbol(symbol)}}
      end
    end
  end

  defp dispatch_call_graph(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required"}
    else
      graph = Mimo.Code.SymbolIndex.call_graph(name)
      {:ok, %{symbol: name, callers: graph.callers, callees: graph.callees}}
    end
  end

  defp dispatch_index(args) do
    path = args["path"] || "."

    if File.dir?(path) do
      case Mimo.Code.SymbolIndex.index_directory(path) do
        {:ok, results} ->
          stats =
            results
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, s} -> s end)

          total_symbols = Enum.reduce(stats, 0, fn s, acc -> acc + s.symbols_added end)
          total_refs = Enum.reduce(stats, 0, fn s, acc -> acc + s.references_added end)

          {:ok,
           %{
             indexed_files: length(stats),
             total_symbols: total_symbols,
             total_references: total_refs
           }}

        error ->
          error
      end
    else
      Mimo.Code.SymbolIndex.index_file(path)
    end
  end

  # ==========================================================================
  # LIBRARY OPERATIONS (from Library dispatcher)
  # ==========================================================================

  defp dispatch_library_get(args) do
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

  defp dispatch_library_search(args) do
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

  defp dispatch_library_ensure(args) do
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

  defp dispatch_library_discover(args) do
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

  # ==========================================================================
  # DIAGNOSTICS OPERATIONS (from Diagnostics dispatcher)
  # ==========================================================================

  defp dispatch_diagnostics(args, operation) do
    path = args["path"]
    opts = [operation: operation]

    opts =
      if args["language"] do
        case Helpers.safe_to_atom(args["language"], Helpers.allowed_languages()) do
          nil -> opts
          lang -> Keyword.put(opts, :language, lang)
        end
      else
        opts
      end

    opts =
      if args["severity"] do
        case Helpers.safe_to_atom(args["severity"], Helpers.allowed_severities()) do
          nil -> opts
          sev -> Keyword.put(opts, :severity, sev)
        end
      else
        opts
      end

    Mimo.Skills.Diagnostics.check(path, opts)
  end
end
