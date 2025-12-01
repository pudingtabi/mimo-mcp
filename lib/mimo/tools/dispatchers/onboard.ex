defmodule Mimo.Tools.Dispatchers.Onboard do
  @moduledoc """
  Project onboarding meta-tool dispatcher.

  SPEC-031 Phase 3: Orchestrates project initialization by running multiple
  indexing operations in sequence:

  1. Check memory for project fingerprint (hash of file tree)
  2. If exists & !force → return cached profile
  3. Run: code_symbols operation=index
  4. Run: library operation=discover
  5. Run: knowledge operation=link
  6. Store fingerprint in memory
  7. Return summary

  This enables all of Mimo's intelligent tools (code_symbols, knowledge, library)
  to work at full capacity from session start.
  """

  require Logger

  alias Mimo.Tools.Dispatchers.{Code, Library, Knowledge}
  alias Mimo.Brain.Memory

  @doc """
  Dispatch onboard operation.

  ## Options
    - path: Project root path (default: ".")
    - force: Re-index even if already done (default: false)
  """
  def dispatch(args) do
    path = args["path"] || "."
    force = Map.get(args, "force", false)

    # Resolve to absolute path
    abs_path = Path.expand(path)

    unless File.dir?(abs_path) do
      {:error, "Path does not exist or is not a directory: #{abs_path}"}
    else
      fingerprint = compute_fingerprint(abs_path)

      # Check if already indexed (unless force)
      if !force && already_indexed?(fingerprint) do
        return_cached_profile(abs_path, fingerprint)
      else
        run_full_onboard(abs_path, fingerprint)
      end
    end
  end

  # ==========================================================================
  # FINGERPRINT MANAGEMENT
  # ==========================================================================

  defp compute_fingerprint(path) do
    # Create fingerprint from directory structure
    files =
      try do
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.take(100)
        |> Enum.join(",")
      rescue
        _ -> "empty"
      end

    # Include key project files in fingerprint
    project_indicators = [
      "mix.exs",
      "package.json",
      "Cargo.toml",
      "requirements.txt",
      "pyproject.toml",
      "go.mod"
    ]

    indicator_hashes =
      project_indicators
      |> Enum.map(fn file ->
        full_path = Path.join(path, file)

        if File.exists?(full_path) do
          case File.stat(full_path) do
            {:ok, stat} -> "#{file}:#{stat.mtime}"
            _ -> nil
          end
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("|")

    # Compute hash
    data = "#{path}|#{files}|#{indicator_hashes}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp already_indexed?(fingerprint) do
    # Search memory for this fingerprint
    results =
      Memory.search_memories("project fingerprint #{fingerprint}", limit: 1, min_similarity: 0.9)

    length(results) > 0
  end

  defp return_cached_profile(path, fingerprint) do
    {:ok,
     %{
       status: "cached",
       path: path,
       fingerprint: fingerprint,
       message: "✅ Project already indexed. Use force=true to re-index.",
       suggestion: "💡 Project context is ready. Use code_symbols, knowledge, and library tools."
     }}
  end

  # ==========================================================================
  # FULL ONBOARDING FLOW
  # ==========================================================================

  defp run_full_onboard(path, fingerprint) do
    Logger.info("[Onboard] Starting project onboard for: #{path}")
    start_time = System.monotonic_time(:millisecond)

    # Step 1: Index code symbols
    symbols_result = run_code_index(path)

    # Step 2: Discover and cache dependencies
    deps_result = run_library_discover(path)

    # Step 3: Link code to knowledge graph
    graph_result = run_knowledge_link(path)

    # Step 4: Store fingerprint in memory
    store_fingerprint(path, fingerprint, symbols_result, deps_result, graph_result)

    duration = System.monotonic_time(:millisecond) - start_time

    # Build summary
    symbols_count = get_in(symbols_result, [:total_symbols]) || 0
    deps_count = get_in(deps_result, [:total_dependencies]) || 0
    nodes_count = get_in(graph_result, [:nodes_created]) || get_in(graph_result, [:nodes]) || 0

    {:ok,
     %{
       status: "indexed",
       path: path,
       fingerprint: fingerprint,
       duration_ms: duration,
       summary:
         "✅ Indexed: #{symbols_count} symbols, #{deps_count} deps, #{nodes_count} graph nodes",
       details: %{
         code_symbols: symbols_result,
         library: deps_result,
         knowledge_graph: graph_result
       },
       suggestion: "💡 Project is now fully indexed. code_symbols, knowledge, and library are ready!"
     }}
  end

  defp run_code_index(path) do
    Logger.debug("[Onboard] Indexing code symbols...")

    case Code.dispatch(%{"operation" => "index", "path" => path}) do
      {:ok, result} ->
        Logger.debug("[Onboard] Code indexing complete: #{inspect(result)}")
        result

      {:error, reason} ->
        Logger.warning("[Onboard] Code indexing failed: #{inspect(reason)}")
        %{error: reason, indexed_files: 0, total_symbols: 0}
    end
  end

  defp run_library_discover(path) do
    Logger.debug("[Onboard] Discovering dependencies...")

    case Library.dispatch(%{"operation" => "discover", "path" => path}) do
      {:ok, result} ->
        Logger.debug("[Onboard] Library discovery complete: #{inspect(result)}")
        result

      {:error, reason} ->
        Logger.warning("[Onboard] Library discovery failed: #{inspect(reason)}")
        %{error: reason, total_dependencies: 0}
    end
  end

  defp run_knowledge_link(path) do
    Logger.debug("[Onboard] Linking to knowledge graph...")

    case Knowledge.dispatch(%{"operation" => "link", "path" => path}) do
      {:ok, result} ->
        Logger.debug("[Onboard] Knowledge linking complete: #{inspect(result)}")
        result

      {:error, reason} ->
        Logger.warning("[Onboard] Knowledge linking failed: #{inspect(reason)}")
        %{error: reason, nodes_created: 0}
    end
  end

  defp store_fingerprint(path, fingerprint, symbols, deps, graph) do
    content = """
    Project onboarded: #{path}
    Fingerprint: #{fingerprint}
    Symbols: #{get_in(symbols, [:total_symbols]) || 0}
    Dependencies: #{get_in(deps, [:total_dependencies]) || 0}
    Graph nodes: #{get_in(graph, [:nodes_created]) || get_in(graph, [:nodes]) || 0}
    Indexed at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """

    Memory.store(%{
      content: content,
      type: "fact",
      metadata: %{
        "fingerprint" => fingerprint,
        "path" => path,
        "category" => "project_onboard"
      }
    })
  end
end
