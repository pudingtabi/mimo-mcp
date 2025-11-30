defmodule Mimo.Code.FileWatcher do
  @moduledoc """
  File watcher for automatic re-indexing on file changes.

  This GenServer monitors project directories for file changes and
  triggers re-indexing when supported source files are modified.
  Part of SPEC-021 Living Codebase.

  ## Usage

      # Start watching a directory
      Mimo.Code.FileWatcher.watch("/path/to/project")

      # Stop watching
      Mimo.Code.FileWatcher.unwatch("/path/to/project")

      # List watched directories
      Mimo.Code.FileWatcher.watched()
  """

  use GenServer
  require Logger

  alias Mimo.Code.{SymbolIndex, TreeSitter}

  @debounce_ms 100
  @name __MODULE__

  # State structure
  defstruct watched_dirs: MapSet.new(),
            pending_changes: %{},
            watcher_pid: nil,
            debounce_ref: nil

  # Client API

  @doc """
  Start the file watcher process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Start watching a directory for changes.
  """
  @spec watch(String.t()) :: :ok | {:error, term()}
  def watch(dir_path) do
    GenServer.call(@name, {:watch, dir_path})
  end

  @doc """
  Stop watching a directory.
  """
  @spec unwatch(String.t()) :: :ok
  def unwatch(dir_path) do
    GenServer.call(@name, {:unwatch, dir_path})
  end

  @doc """
  List all watched directories.
  """
  @spec watched() :: [String.t()]
  def watched do
    GenServer.call(@name, :watched)
  end

  @doc """
  Manually trigger re-indexing for a file.
  """
  @spec reindex(String.t()) :: {:ok, map()} | {:error, term()}
  def reindex(file_path) do
    GenServer.call(@name, {:reindex, file_path}, 30_000)
  end

  @doc """
  Get current status of the file watcher.
  """
  @spec status() :: map()
  def status do
    GenServer.call(@name, :status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting FileWatcher")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:watch, dir_path}, _from, state) do
    if File.dir?(dir_path) do
      abs_path = Path.expand(dir_path)

      case start_watching(abs_path, state) do
        {:ok, new_state} ->
          Logger.info("FileWatcher: Started watching #{abs_path}")
          {:reply, :ok, new_state}

        {:error, reason} ->
          Logger.error("FileWatcher: Failed to watch #{abs_path}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_a_directory}, state}
    end
  end

  def handle_call({:unwatch, dir_path}, _from, state) do
    abs_path = Path.expand(dir_path)
    new_state = stop_watching(abs_path, state)
    Logger.info("FileWatcher: Stopped watching #{abs_path}")
    {:reply, :ok, new_state}
  end

  def handle_call(:watched, _from, state) do
    {:reply, MapSet.to_list(state.watched_dirs), state}
  end

  def handle_call({:reindex, file_path}, _from, state) do
    result = do_reindex(file_path)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      watched_dirs: MapSet.to_list(state.watched_dirs),
      pending_changes: map_size(state.pending_changes),
      watcher_active: state.watcher_pid != nil
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Only process supported files
    if should_process?(path, events) do
      Logger.debug("FileWatcher: Change detected in #{path}: #{inspect(events)}")
      new_state = schedule_reindex(path, state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("FileWatcher: Watcher stopped unexpectedly")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(:process_pending, state) do
    # Process all pending changes
    state.pending_changes
    |> Map.keys()
    |> Enum.each(fn path ->
      spawn(fn -> do_reindex(path) end)
    end)

    {:noreply, %{state | pending_changes: %{}, debounce_ref: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("FileWatcher: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helpers

  defp start_watching(dir_path, state) do
    # Check if file_system is available
    if Code.ensure_loaded?(FileSystem) do
      # Stop existing watcher if any
      state = maybe_stop_watcher(state)

      # Collect all directories to watch
      new_watched = MapSet.put(state.watched_dirs, dir_path)

      # Start a single watcher for all directories
      dirs_to_watch = MapSet.to_list(new_watched)

      case FileSystem.start_link(dirs: dirs_to_watch, name: :code_file_watcher) do
        {:ok, pid} ->
          FileSystem.subscribe(:code_file_watcher)
          {:ok, %{state | watched_dirs: new_watched, watcher_pid: pid}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.warning("FileWatcher: file_system dependency not available, watching disabled")
      {:ok, %{state | watched_dirs: MapSet.put(state.watched_dirs, dir_path)}}
    end
  end

  defp stop_watching(dir_path, state) do
    new_watched = MapSet.delete(state.watched_dirs, dir_path)

    if MapSet.size(new_watched) == 0 do
      maybe_stop_watcher(state)
      %{state | watched_dirs: new_watched, watcher_pid: nil}
    else
      # Restart watcher with remaining directories
      state = maybe_stop_watcher(state)

      case start_watching_dirs(MapSet.to_list(new_watched)) do
        {:ok, pid} ->
          %{state | watched_dirs: new_watched, watcher_pid: pid}

        {:error, _} ->
          %{state | watched_dirs: new_watched, watcher_pid: nil}
      end
    end
  end

  defp start_watching_dirs(dirs) do
    if Code.ensure_loaded?(FileSystem) and length(dirs) > 0 do
      case FileSystem.start_link(dirs: dirs, name: :code_file_watcher) do
        {:ok, pid} ->
          FileSystem.subscribe(:code_file_watcher)
          {:ok, pid}

        error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_stop_watcher(%{watcher_pid: nil} = state), do: state

  defp maybe_stop_watcher(%{watcher_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    %{state | watcher_pid: nil}
  end

  defp should_process?(path, events) do
    # Only process if it's a supported file and was modified/created
    relevant_events = [:modified, :created, :renamed]

    TreeSitter.supported_file?(path) and
      Enum.any?(events, &(&1 in relevant_events))
  end

  defp schedule_reindex(path, state) do
    # Cancel previous debounce timer if any
    if state.debounce_ref do
      Process.cancel_timer(state.debounce_ref)
    end

    # Add to pending changes
    new_pending = Map.put(state.pending_changes, path, :pending)

    # Schedule processing after debounce period
    ref = Process.send_after(self(), :process_pending, @debounce_ms)

    %{state | pending_changes: new_pending, debounce_ref: ref}
  end

  defp do_reindex(file_path) do
    if File.exists?(file_path) do
      Logger.info("FileWatcher: Re-indexing #{file_path}")

      case SymbolIndex.index_file(file_path) do
        {:ok, stats} ->
          # SPEC-025: Notify Orchestrator to sync to Synapse graph
          symbols = SymbolIndex.symbols_in_file(file_path)
          notify_orchestrator(file_path, symbols)
          {:ok, stats}

        error ->
          error
      end
    else
      Logger.info("FileWatcher: File deleted, removing from index: #{file_path}")
      SymbolIndex.remove_file(file_path)
    end
  end

  # Notify the Synapse Orchestrator about file changes (SPEC-025)
  defp notify_orchestrator(file_path, symbols) do
    if Process.whereis(Mimo.Synapse.Orchestrator) do
      Mimo.Synapse.Orchestrator.on_file_indexed(file_path, symbols)
    else
      Logger.debug("FileWatcher: Orchestrator not available, skipping graph sync")
    end
  rescue
    e ->
      Logger.warning("FileWatcher: Failed to notify orchestrator: #{Exception.message(e)}")
  end
end
