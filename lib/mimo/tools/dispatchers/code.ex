defmodule Mimo.Tools.Dispatchers.Code do
  @moduledoc """
  Code symbols operations dispatcher.

  Handles code structure analysis using Tree-Sitter:
  - parse: Parse file or source code
  - symbols: List symbols in file/directory (Code.SymbolIndex.symbols_in_file)
  - references: Find all references (Code.SymbolIndex.find_references)
  - search: Search symbols by pattern (Code.SymbolIndex.search)
  - definition: Find symbol definition (Code.SymbolIndex.find_definition)
  - call_graph: Get callers and callees (Code.SymbolIndex.call_graph)
  - index: Index file/directory (Code.SymbolIndex.index_file / index_directory)

  Supports: Elixir, Python, JavaScript, TypeScript, TSX
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch code_symbols operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "symbols"

    case op do
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

      _ ->
        {:error, "Unknown code_symbols operation: #{op}"}
    end
  end

  # ==========================================================================
  # PRIVATE HELPERS
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
end
