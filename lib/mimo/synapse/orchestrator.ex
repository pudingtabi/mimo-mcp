defmodule Mimo.Synapse.Orchestrator do
  @moduledoc """
  Coordinates updates to the Synapse graph from various sources.

  Part of SPEC-025: Cognitive Codebase Integration.

  Listens to events from:
  - FileWatcher (code changes) - triggers code → graph synchronization
  - Memory storage (new engrams) - links memories to related code
  - Library cache (new packages) - connects dependencies to graph
  - SymbolIndex updates - creates nodes for indexed symbols

  ## Architecture

      FileWatcher ──┐
                    │
      Memory ───────┼──► Orchestrator ──► Synapse Graph
                    │
      Library ──────┘

  ## Example

      # When a file is indexed
      Orchestrator.on_file_indexed("/path/to/file.ex", symbols)

      # When a memory is stored
      Orchestrator.on_memory_stored(engram)

      # When a library is cached
      Orchestrator.on_library_cached("phoenix", :hex)
  """

  use GenServer
  require Logger

  alias MemoryLinker
  alias Mimo.Code.SymbolIndex
  alias Mimo.Synapse.{Graph, Linker}

  @name __MODULE__

  # Debounce settings for batch processing
  @batch_delay_ms 500
  @max_batch_size 100

  # State structure
  defstruct pending_files: [],
            pending_memories: [],
            pending_libraries: [],
            batch_timer: nil,
            stats: %{
              files_processed: 0,
              memories_linked: 0,
              libraries_synced: 0,
              nodes_created: 0,
              edges_created: 0
            }

  @doc """
  Start the orchestrator process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Called when a file has been indexed by SymbolIndex.

  Creates/updates graph nodes for:
  - The file itself (:file node)
  - All functions/modules (:function/:module nodes)
  - Edges between them (:defines, :calls, :imports)
  """
  @spec on_file_indexed(String.t(), list()) :: :ok
  def on_file_indexed(file_path, symbols \\ []) do
    GenServer.cast(@name, {:file_indexed, file_path, symbols})
  end

  @doc """
  Called when a memory (engram) is stored.

  Analyzes content and creates links to:
  - Mentioned files
  - Referenced functions
  - Related concepts
  """
  @spec on_memory_stored(map() | struct()) :: :ok
  def on_memory_stored(engram) do
    GenServer.cast(@name, {:memory_stored, engram})
  end

  @doc """
  Called when a library is cached.

  Creates :external_lib node and links to:
  - Code that imports it
  - Related documentation
  """
  @spec on_library_cached(String.t(), atom()) :: :ok
  def on_library_cached(package_name, ecosystem) do
    GenServer.cast(@name, {:library_cached, package_name, ecosystem})
  end

  @doc """
  Called when a dependency is detected in project files.

  Creates :depends_on edges from project to packages.
  """
  @spec on_dependency_detected(String.t(), String.t(), atom()) :: :ok
  def on_dependency_detected(dep_name, dep_version, ecosystem) do
    GenServer.cast(@name, {:dependency_detected, dep_name, dep_version, ecosystem})
  end

  @doc """
  Trigger a full sync of a directory to the graph.

  Indexes all files and creates the complete graph structure.
  """
  @spec sync_directory(String.t()) :: {:ok, map()} | {:error, term()}
  def sync_directory(dir_path) do
    GenServer.call(@name, {:sync_directory, dir_path}, 60_000)
  end

  @doc """
  Get orchestrator statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Force process any pending items immediately.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(@name, :flush)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Orchestrator] Starting Synapse Orchestrator (SPEC-025)")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:file_indexed, file_path, symbols}, state) do
    new_pending = [{file_path, symbols} | state.pending_files]
    new_state = %{state | pending_files: new_pending}

    # Schedule batch processing
    new_state = maybe_schedule_batch(new_state)

    {:noreply, new_state}
  end

  def handle_cast({:memory_stored, engram}, state) do
    new_pending = [engram | state.pending_memories]
    new_state = %{state | pending_memories: new_pending}
    new_state = maybe_schedule_batch(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:library_cached, package_name, ecosystem}, state) do
    new_pending = [{package_name, ecosystem} | state.pending_libraries]
    new_state = %{state | pending_libraries: new_pending}
    new_state = maybe_schedule_batch(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:dependency_detected, dep_name, dep_version, ecosystem}, state) do
    # Process dependency immediately (they're less frequent)
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      try do
        sync_dependency(dep_name, dep_version, ecosystem)
      rescue
        e ->
          Logger.error(
            "[Orchestrator] Failed to sync dependency #{dep_name}: #{Exception.message(e)}"
          )

          :telemetry.execute([:mimo, :orchestrator, :sync_dependency_error], %{count: 1}, %{
            dependency: dep_name,
            ecosystem: ecosystem,
            error: Exception.message(e)
          })
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:sync_directory, dir_path}, _from, state) do
    result = do_sync_directory(dir_path, state)
    {:reply, result, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:flush, _from, state) do
    new_state = process_batch(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:process_batch, state) do
    new_state = %{state | batch_timer: nil}
    new_state = process_batch(new_state)
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Orchestrator] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_schedule_batch(%{batch_timer: nil} = state) do
    timer = Process.send_after(self(), :process_batch, @batch_delay_ms)
    %{state | batch_timer: timer}
  end

  defp maybe_schedule_batch(state), do: state

  defp process_batch(state) do
    # In test (sandbox) mode, drop queued work to avoid DB ownership issues
    if Mimo.Sandbox.sandbox_mode?() do
      Logger.debug(
        "[Orchestrator] Test mode detected; dropping pending batches (files=#{length(state.pending_files)}, memories=#{length(state.pending_memories)}, libs=#{length(state.pending_libraries)})"
      )

      %{state | pending_files: [], pending_memories: [], pending_libraries: []}
    else
      # Wrap in safe_db_operation to handle sandbox/connection errors gracefully
      safe_db_operation(fn ->
        # Process files
        {files_to_process, remaining_files} = Enum.split(state.pending_files, @max_batch_size)
        file_stats = process_pending_files(files_to_process)

        # Process memories
        {memories_to_process, remaining_memories} =
          Enum.split(state.pending_memories, @max_batch_size)

        memory_stats = process_pending_memories(memories_to_process)

        # Process libraries
        {libs_to_process, remaining_libs} = Enum.split(state.pending_libraries, @max_batch_size)
        lib_stats = process_pending_libraries(libs_to_process)

        # Update stats
        new_stats = %{
          files_processed: state.stats.files_processed + file_stats.count,
          memories_linked: state.stats.memories_linked + memory_stats.count,
          libraries_synced: state.stats.libraries_synced + lib_stats.count,
          nodes_created:
            state.stats.nodes_created + file_stats.nodes + memory_stats.nodes + lib_stats.nodes,
          edges_created:
            state.stats.edges_created + file_stats.edges + memory_stats.edges + lib_stats.edges
        }

        %{
          state
          | pending_files: remaining_files,
            pending_memories: remaining_memories,
            pending_libraries: remaining_libs,
            stats: new_stats
        }
      end)
      |> case do
        # Return unchanged state on sandbox/connection error
        {:error, :test_mode} -> state
        result -> result
      end
    end
  end

  defp process_pending_files([]), do: %{count: 0, nodes: 0, edges: 0}

  defp process_pending_files(files) do
    results =
      files
      |> Enum.map(fn {file_path, symbols} ->
        sync_file_to_graph(file_path, symbols)
      end)

    nodes = Enum.sum(Enum.map(results, fn r -> r[:nodes] || 0 end))
    edges = Enum.sum(Enum.map(results, fn r -> r[:edges] || 0 end))

    Logger.info("[Orchestrator] Processed #{length(files)} files → #{nodes} nodes, #{edges} edges")

    %{count: length(files), nodes: nodes, edges: edges}
  end

  defp sync_file_to_graph(file_path, symbols) do
    # Use Linker if symbols are empty (it will fetch them)
    if symbols == [] do
      case Linker.link_code_file(file_path) do
        {:ok, stats} ->
          %{nodes: stats.symbols_linked + 1, edges: stats.refs_linked + stats.symbols_linked}

        {:error, _reason} ->
          %{nodes: 0, edges: 0}
      end
    else
      # Create nodes from provided symbols
      create_nodes_from_symbols(file_path, symbols)
    end
  rescue
    e ->
      Logger.warning("[Orchestrator] Error syncing file #{file_path}: #{Exception.message(e)}")
      %{nodes: 0, edges: 0}
  end

  defp create_nodes_from_symbols(file_path, symbols) do
    # Create file node
    {:ok, file_node} =
      Graph.find_or_create_node(:file, file_path, %{
        language: detect_language(file_path),
        indexed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # Create nodes for each symbol
    symbol_results =
      symbols
      |> Enum.map(fn symbol ->
        node_type = symbol_kind_to_node_type(symbol)
        name = symbol[:qualified_name] || symbol[:name] || symbol.qualified_name || symbol.name

        {:ok, symbol_node} =
          Graph.find_or_create_node(node_type, name, %{
            language: symbol[:language] || symbol.language,
            file_path: file_path,
            start_line: symbol[:start_line] || symbol.start_line,
            end_line: symbol[:end_line] || symbol.end_line,
            kind: symbol[:kind] || symbol.kind,
            source_ref_type: "code_symbol",
            source_ref_id: symbol[:id] || to_string(symbol.id)
          })

        # Create defines edge
        Graph.ensure_edge(file_node.id, symbol_node.id, :defines, %{source: "orchestrator"})

        symbol_node
      end)

    %{nodes: length(symbol_results) + 1, edges: length(symbol_results)}
  rescue
    e ->
      Logger.warning("[Orchestrator] Error creating nodes: #{Exception.message(e)}")
      %{nodes: 0, edges: 0}
  end

  defp process_pending_memories([]), do: %{count: 0, nodes: 0, edges: 0}

  defp process_pending_memories(memories) do
    results =
      memories
      |> Enum.map(&link_memory_to_graph/1)

    nodes = Enum.sum(Enum.map(results, fn r -> r[:nodes] || 0 end))
    edges = Enum.sum(Enum.map(results, fn r -> r[:edges] || 0 end))

    Logger.info("[Orchestrator] Linked #{length(memories)} memories → #{edges} edges")

    %{count: length(memories), nodes: nodes, edges: edges}
  end

  defp link_memory_to_graph(engram) do
    # Use MemoryLinker for intelligent content analysis and linking
    engram_id = get_engram_id(engram)
    content = get_engram_content(engram)

    case Mimo.Brain.MemoryLinker.link_memory(engram_id, content) do
      {:ok, stats} ->
        %{nodes: 1, edges: stats.total}

      {:error, reason} ->
        # Log but don't fail - this can happen in test mode without sandbox access
        Logger.debug("[Orchestrator] Failed to link memory #{engram_id}: #{inspect(reason)}")
        %{nodes: 0, edges: 0}
    end
  rescue
    e ->
      # Handle sandbox ownership errors gracefully (common in tests)
      Logger.debug("[Orchestrator] Error linking memory: #{Exception.message(e)}")
      %{nodes: 0, edges: 0}
  catch
    :exit, reason ->
      Logger.debug("[Orchestrator] Exit while linking memory: #{inspect(reason)}")
      %{nodes: 0, edges: 0}
  end

  defp get_engram_id(%{id: id}), do: id
  defp get_engram_id(%{"id" => id}), do: id
  defp get_engram_id(id) when is_integer(id) or is_binary(id), do: id
  defp get_engram_id(_), do: nil

  defp get_engram_content(%{content: content}), do: content
  defp get_engram_content(%{"content" => content}), do: content
  defp get_engram_content(_), do: nil

  defp process_pending_libraries([]), do: %{count: 0, nodes: 0, edges: 0}

  defp process_pending_libraries(libraries) do
    results =
      libraries
      |> Enum.map(fn {name, ecosystem} ->
        sync_library_to_graph(name, ecosystem)
      end)

    nodes = Enum.sum(Enum.map(results, fn r -> r[:nodes] || 0 end))
    edges = Enum.sum(Enum.map(results, fn r -> r[:edges] || 0 end))

    Logger.info("[Orchestrator] Synced #{length(libraries)} libraries → #{nodes} nodes")

    %{count: length(libraries), nodes: nodes, edges: edges}
  end

  defp sync_library_to_graph(package_name, ecosystem) do
    {:ok, _node} =
      Graph.find_or_create_node(:external_lib, package_name, %{
        ecosystem: to_string(ecosystem),
        synced_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    %{nodes: 1, edges: 0}
  rescue
    e ->
      Logger.warning(
        "[Orchestrator] Error syncing library #{package_name}: #{Exception.message(e)}"
      )

      %{nodes: 0, edges: 0}
  end

  defp sync_dependency(dep_name, dep_version, ecosystem) do
    # Create library node
    {:ok, lib_node} =
      Graph.find_or_create_node(:external_lib, dep_name, %{
        ecosystem: to_string(ecosystem),
        version: dep_version,
        dependency: true
      })

    # Create project node if it doesn't exist
    project_name = System.get_env("MIMO_PROJECT") || "project"

    {:ok, project_node} =
      Graph.find_or_create_node(:module, project_name, %{
        type: "project",
        is_root: true
      })

    # Create depends_on edge
    Graph.ensure_edge(project_node.id, lib_node.id, :uses, %{
      source: "dependency_sync",
      version: dep_version
    })

    :ok
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug("[Orchestrator] Skipping dependency sync in test mode: #{Exception.message(e)}")
      :ok

    e ->
      Logger.warning("[Orchestrator] Error syncing dependency #{dep_name}: #{Exception.message(e)}")
      :error
  end

  # Helper to wrap DB operations and handle sandbox errors gracefully
  defp safe_db_operation(fun) do
    try do
      fun.()
    rescue
      e in DBConnection.OwnershipError ->
        Logger.debug(
          "[Orchestrator] Skipping DB operation in test mode (ownership): #{Exception.message(e)}"
        )

        {:error, :test_mode}

      e in DBConnection.ConnectionError ->
        Logger.debug(
          "[Orchestrator] Skipping DB operation in test mode (connection): #{Exception.message(e)}"
        )

        {:error, :test_mode}
    end
  end

  defp do_sync_directory(dir_path, _state) do
    Logger.info("[Orchestrator] Syncing directory: #{dir_path}")

    # First, index the directory
    case SymbolIndex.index_directory(dir_path) do
      {:ok, index_results} ->
        # Count successful indexes
        successes =
          index_results
          |> Enum.filter(fn
            {:ok, _} -> true
            _ -> false
          end)

        # Link all indexed files to graph
        link_result = Linker.link_directory(dir_path)

        case link_result do
          {:ok, link_stats} ->
            {:ok,
             %{
               indexed_files: length(successes),
               symbols_linked: link_stats.total_symbols,
               references_linked: link_stats.total_references,
               graph_files_processed: link_stats.files_processed
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e ->
      Logger.error("[Orchestrator] Directory sync failed: #{Exception.message(e)}")
      {:error, e}
  end

  defp symbol_kind_to_node_type(%{kind: kind}), do: kind_to_type(kind)
  defp symbol_kind_to_node_type(%{"kind" => kind}), do: kind_to_type(kind)
  defp symbol_kind_to_node_type(_), do: :function

  defp kind_to_type("function"), do: :function
  defp kind_to_type("method"), do: :function
  defp kind_to_type("module"), do: :module
  defp kind_to_type("class"), do: :module
  defp kind_to_type("interface"), do: :module
  defp kind_to_type("macro"), do: :function
  defp kind_to_type(_), do: :function

  defp detect_language(file_path) do
    case Path.extname(file_path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".py" -> "python"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".jsx" -> "javascript"
      ".rs" -> "rust"
      ".go" -> "go"
      _ -> "unknown"
    end
  end
end
