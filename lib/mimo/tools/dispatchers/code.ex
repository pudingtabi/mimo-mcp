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

  alias Mimo.Code.SymbolIndex
  alias Mimo.Code.TreeSitter
  alias Mimo.Context.{Entity, WorkingMemory}
  alias Mimo.Library.AutoDiscovery
  alias Mimo.Library.CacheManager
  alias Mimo.Library.Index
  alias Mimo.Skills.Diagnostics
  alias Mimo.Tools.Helpers
  alias Mimo.Utils.InputValidation

  @doc """
  Dispatch code operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "symbols"
    do_dispatch(op, args)
  end

  # Code Symbols Operations
  defp do_dispatch("parse", args), do: dispatch_parse(args)
  defp do_dispatch("symbols", args), do: dispatch_symbols(args)
  defp do_dispatch("references", args), do: dispatch_references(args)
  defp do_dispatch("search", args), do: dispatch_search(args)
  defp do_dispatch("definition", args), do: dispatch_definition(args)
  defp do_dispatch("call_graph", args), do: dispatch_call_graph(args)
  defp do_dispatch("index", args), do: dispatch_index(args)

  # Library Operations
  defp do_dispatch("library", args), do: dispatch_library_get(args)
  defp do_dispatch("library_get", args), do: dispatch_library_get(args)
  defp do_dispatch("library_search", args), do: dispatch_library_search(args)
  defp do_dispatch("library_ensure", args), do: dispatch_library_ensure(args)
  defp do_dispatch("library_discover", args), do: dispatch_library_discover(args)
  defp do_dispatch("library_stats", _args), do: {:ok, CacheManager.stats()}

  # Diagnostics Operations
  defp do_dispatch("check", args), do: dispatch_diagnostics(args, :check)
  defp do_dispatch("lint", args), do: dispatch_diagnostics(args, :lint)
  defp do_dispatch("typecheck", args), do: dispatch_diagnostics(args, :typecheck)
  defp do_dispatch("diagnose", args), do: dispatch_diagnostics(args, :all)
  defp do_dispatch("diagnostics_all", args), do: dispatch_diagnostics(args, :all)

  # Unknown operation
  defp do_dispatch(op, _args) do
    {:error,
     "Unknown code operation: #{op}. Valid operations: " <>
       "symbols, parse, references, search, definition, call_graph, index, " <>
       "library, library_get, library_search, library_ensure, library_discover, library_stats, " <>
       "check, lint, typecheck, diagnose, diagnostics_all"}
  end

  defp dispatch_parse(args) do
    do_parse(args["path"], args["source"], args["language"])
  end

  defp do_parse(path, _source, _lang) when is_binary(path) and path != "" do
    with {:ok, tree} <- TreeSitter.parse_file(path),
         {:ok, sexp} <- TreeSitter.get_sexp(tree) do
      {:ok, %{parsed: true, sexp: String.slice(sexp, 0, 2000)}}
    end
  end

  defp do_parse(_path, source, lang) when is_binary(source) and is_binary(lang) do
    with {:ok, tree} <- TreeSitter.parse(source, lang),
         {:ok, symbols} <- TreeSitter.get_symbols(tree),
         {:ok, refs} <- TreeSitter.get_references(tree) do
      {:ok, %{parsed: true, symbols: symbols, references: refs}}
    end
  end

  defp do_parse(_path, _source, _lang) do
    {:error, "Either path or source+language is required"}
  end

  defp dispatch_symbols(args) do
    cond do
      args["path"] && File.dir?(args["path"]) ->
        # List symbols in directory
        case SymbolIndex.index_directory(args["path"]) do
          {:ok, _} ->
            stats = SymbolIndex.stats()
            {:ok, stats}

          error ->
            error
        end

      args["path"] ->
        # List symbols in file - auto-index if empty (SPEC-105 improvement)
        symbols = SymbolIndex.symbols_in_file(args["path"])

        # If no symbols found and file exists, try indexing it first
        symbols =
          if symbols == [] and File.exists?(args["path"]) do
            case SymbolIndex.index_file(args["path"]) do
              {:ok, _stats} -> SymbolIndex.symbols_in_file(args["path"])
              _ -> symbols
            end
          else
            symbols
          end

        {:ok,
         %{
           file: args["path"],
           symbols: Enum.map(symbols, &Helpers.format_symbol/1),
           count: length(symbols)
         }}

      true ->
        # Return index stats
        {:ok, SymbolIndex.stats()}
    end
  end

  defp dispatch_references(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required for references lookup"}
    else
      # Validate limit to prevent excessive results
      limit = InputValidation.validate_limit(args["limit"], default: 50, max: 500)
      refs = SymbolIndex.find_references(name, limit: limit)

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
      # Validate limit
      limit = InputValidation.validate_limit(args["limit"], default: 50, max: 500)
      opts = Keyword.put(opts, :limit, limit)

      symbols = SymbolIndex.search(pattern, opts)

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
      case SymbolIndex.find_definition(name) do
        nil ->
          {:ok, %{symbol: name, found: false}}

        symbol ->
          # SPEC-097: Auto-track discovered symbols as entities
          maybe_track_entity(name, symbol)
          {:ok, %{symbol: name, found: true, definition: Helpers.format_symbol(symbol)}}
      end
    end
  end

  # SPEC-097: Auto-track symbols as entities for "that module" resolution
  defp maybe_track_entity(name, symbol) do
    spawn(fn ->
      try do
        project = WorkingMemory.current_project()
        type = infer_entity_type(symbol)
        context = "#{symbol.kind} defined in #{symbol.file}"

        Entity.track(name, type, project, context)
      rescue
        _ -> :ok
      end
    end)
  end

  defp infer_entity_type(symbol) do
    case symbol.kind do
      kind when kind in [:function, :def, :defp] -> :function
      kind when kind in [:module, :defmodule] -> :module
      kind when kind in [:class] -> :module
      kind when kind in [:variable, :const, :let] -> :variable
      kind when kind in [:struct, :record, :type] -> :concept
      _ -> :other
    end
  end

  defp dispatch_call_graph(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required"}
    else
      graph = SymbolIndex.call_graph(name)
      {:ok, %{symbol: name, callers: graph.callers, callees: graph.callees}}
    end
  end

  defp dispatch_index(args) do
    path = args["path"] || "."

    if File.dir?(path) do
      case SymbolIndex.index_directory(path) do
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
      SymbolIndex.index_file(path)
    end
  end

  defp dispatch_library_get(args) do
    name = args["name"]
    ecosystem = Helpers.parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Index.get_package(name, ecosystem, opts) do
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
    # Validate limit
    limit = InputValidation.validate_limit(args["limit"], default: 10, max: 100)

    if query == "" do
      {:error, "Search query is required"}
    else
      # First search local cache
      cached_results = Index.search(query, ecosystem: ecosystem, limit: limit)

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
        if name, do: Index.ensure_cached(name, ecosystem, [])
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

  defp dispatch_library_ensure(args) do
    name = args["name"]
    ecosystem = Helpers.parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Index.ensure_cached(name, ecosystem, opts) do
        :ok ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: true}}

        {:error, reason} ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: false, error: inspect(reason)}}
      end
    end
  end

  defp dispatch_library_discover(args) do
    path = args["path"] || File.cwd!()

    case AutoDiscovery.discover_and_cache(path) do
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

    Diagnostics.check(path, opts)
  end
end
