defmodule Mimo.Brain.HnswIndex do
  @moduledoc """
  GenServer managing the HNSW index for approximate nearest neighbor search.

  This module provides a persistent HNSW index that:
  - Loads from disk on startup if available
  - Auto-saves periodically and on shutdown
  - Provides O(log n) approximate nearest neighbor search
  - Uses int8 quantized vectors for memory efficiency

  ## SPEC-033 Phase 3b Implementation

  The HnswIndex is designed to work alongside the existing memory search:
  - For < 1000 memories: Use binary pre-filter → int8 rescore (two-stage)
  - For >= 1000 memories: Use HNSW index for fast ANN search

  ## Usage

      # Start with application (auto-loads existing index)
      {:ok, _pid} = Mimo.Brain.HnswIndex.start_link()

      # Search for nearest neighbors
      {:ok, results} = Mimo.Brain.HnswIndex.search(query_binary, 10)

      # Add a new vector
      :ok = Mimo.Brain.HnswIndex.add(engram_id, int8_binary)

      # Build index from scratch
      :ok = Mimo.Brain.HnswIndex.rebuild()

  ## Configuration

  Configure in config.exs:

      config :mimo_mcp, Mimo.Brain.HnswIndex,
        dimensions: 256,
        connectivity: 16,
        expansion_add: 128,
        expansion_search: 64,
        auto_save_interval: :timer.minutes(5),
        index_path: "priv/hnsw_index.usearch"
  """

  use GenServer

  require Logger

  alias Mimo.Vector.Math
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  import Ecto.Query

  # Default configuration
  @default_dimensions 256
  @default_connectivity 16
  @default_expansion_add 128
  @default_expansion_search 64
  @default_auto_save_interval :timer.minutes(5)
  @default_index_path "priv/hnsw_index.usearch"

  # Minimum vectors before using HNSW (below this, two-stage search is faster)
  @hnsw_threshold 1000

  defstruct [
    :index,
    :dimensions,
    :index_path,
    :auto_save_interval,
    :last_saved_at,
    :dirty,
    :vector_count,
    :initialized
  ]

  @type t :: %__MODULE__{
          index: reference() | nil,
          dimensions: pos_integer(),
          index_path: String.t(),
          auto_save_interval: pos_integer(),
          last_saved_at: DateTime.t() | nil,
          dirty: boolean(),
          vector_count: non_neg_integer(),
          initialized: boolean()
        }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Starts the HnswIndex GenServer.

  ## Options

    - `:dimensions` - Vector dimensions (default: 256)
    - `:connectivity` - HNSW M parameter (default: 16)
    - `:expansion_add` - ef_construction parameter (default: 128)
    - `:expansion_search` - ef parameter (default: 64)
    - `:auto_save_interval` - Milliseconds between auto-saves (default: 5 minutes)
    - `:index_path` - Path to save/load index (default: "priv/hnsw_index.usearch")
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Searches for the k nearest neighbors of a query vector.

  ## Parameters

    - `query_int8` - Int8 quantized query vector as binary
    - `k` - Number of neighbors to return (default: 10)

  ## Returns

    - `{:ok, [{engram_id, distance}, ...]}` - List of results sorted by distance
    - `{:error, :not_initialized}` - Index not ready
    - `{:error, :below_threshold}` - Not enough vectors for HNSW (use two-stage search)
    - `{:error, reason}` - Other errors
  """
  @spec search(binary(), pos_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, atom() | String.t()}
  def search(query_int8, k \\ 10) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:search, query_int8, k}, :timer.seconds(30))
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Adds a single vector to the index.

  ## Parameters

    - `key` - Engram ID
    - `vector_int8` - Int8 quantized embedding as binary

  ## Returns

    - `:ok` - Success
    - `{:error, reason}` - Error
  """
  @spec add(non_neg_integer(), binary()) :: :ok | {:error, atom() | String.t()}
  def add(key, vector_int8) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:add, key, vector_int8})
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Adds multiple vectors to the index in batch.

  ## Parameters

    - `entries` - List of `{engram_id, int8_binary}` tuples

  ## Returns

    - `{:ok, count_added}` - Number of vectors added
    - `{:error, reason}` - Error
  """
  @spec add_batch([{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer()} | {:error, atom() | String.t()}
  def add_batch(entries) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:add_batch, entries}, :timer.minutes(5))
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Removes a vector from the index.

  ## Parameters

    - `key` - Engram ID to remove

  ## Returns

    - `:ok` - Success
    - `{:error, reason}` - Error
  """
  @spec remove(non_neg_integer()) :: :ok | {:error, atom() | String.t()}
  def remove(key) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:remove, key})
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Checks if a key exists in the index.

  ## Parameters

    - `key` - Engram ID to check

  ## Returns

    - `boolean()` - Whether key exists
  """
  @spec contains?(non_neg_integer()) :: boolean()
  def contains?(key) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:contains, key})
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  @doc """
  Forces a save of the index to disk.

  ## Returns

    - `:ok` - Success
    - `{:error, reason}` - Error
  """
  @spec save() :: :ok | {:error, atom() | String.t()}
  def save do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, :save)
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Rebuilds the index from all engrams in the database.

  This is a heavy operation that should be run during maintenance windows
  or initial setup. Progress is logged.

  ## Returns

    - `{:ok, count}` - Number of vectors indexed
    - `{:error, reason}` - Error
  """
  @spec rebuild() :: {:ok, non_neg_integer()} | {:error, atom() | String.t()}
  def rebuild do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, :rebuild, :timer.minutes(30))
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Gets statistics about the index.

  ## Returns

    - Map with :size, :capacity, :dimensions, :memory_usage, :initialized, :threshold
    - Returns disabled status map if GenServer is not running
  """
  @spec stats() :: map()
  def stats do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, :stats)
      catch
        :exit, _ -> %{available: false, error: :not_running, threshold: @hnsw_threshold}
      end
    else
      %{available: false, reason: :disabled, threshold: @hnsw_threshold}
    end
  end

  @doc """
  Checks if HNSW search should be used based on vector count.

  Returns true if there are enough vectors to benefit from HNSW.
  Returns false if the GenServer is not running (feature disabled).
  """
  @spec should_use_hnsw?() :: boolean()
  def should_use_hnsw? do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, :should_use_hnsw)
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  @doc """
  Gets the minimum threshold for using HNSW search.
  """
  @spec threshold() :: non_neg_integer()
  def threshold, do: @hnsw_threshold

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    # Check if HNSW NIF is available BEFORE proceeding
    if Math.hnsw_available?() do
      # Get configuration
      config = Application.get_env(:mimo_mcp, __MODULE__, [])
      merged_opts = Keyword.merge(config, opts)

      dimensions = Keyword.get(merged_opts, :dimensions, @default_dimensions)
      connectivity = Keyword.get(merged_opts, :connectivity, @default_connectivity)
      expansion_add = Keyword.get(merged_opts, :expansion_add, @default_expansion_add)
      expansion_search = Keyword.get(merged_opts, :expansion_search, @default_expansion_search)

      auto_save_interval =
        Keyword.get(merged_opts, :auto_save_interval, @default_auto_save_interval)

      index_path = Keyword.get(merged_opts, :index_path, @default_index_path)

      state = %__MODULE__{
        index: nil,
        dimensions: dimensions,
        index_path: index_path,
        auto_save_interval: auto_save_interval,
        last_saved_at: nil,
        dirty: false,
        vector_count: 0,
        initialized: false
      }

      # Try to load existing index or create new one
      {:ok, state, {:continue, {:init_index, connectivity, expansion_add, expansion_search}}}
    else
      Logger.warning(
        "⚠️ HNSW NIF not available - index will not be used. Memory search falls back to two-stage strategy."
      )

      # Return :ignore so supervisor doesn't keep trying to restart
      :ignore
    end
  end

  @impl true
  def handle_continue({:init_index, connectivity, expansion_add, expansion_search}, state) do
    new_state =
      if File.exists?(state.index_path) do
        Logger.info("Loading HNSW index from #{state.index_path}")

        case Math.hnsw_load(state.index_path) do
          {:ok, index} ->
            size =
              case Math.hnsw_size(index) do
                {:ok, s} -> s
                {:error, _} -> 0
              end

            Logger.info("HNSW index loaded with #{size} vectors")

            %{
              state
              | index: index,
                vector_count: size,
                initialized: true,
                last_saved_at: DateTime.utc_now()
            }

          {:error, reason} ->
            Logger.warning("Failed to load HNSW index: #{inspect(reason)}, creating new")
            create_new_index(state, connectivity, expansion_add, expansion_search)
        end
      else
        Logger.info("Creating new HNSW index with #{state.dimensions} dimensions")
        create_new_index(state, connectivity, expansion_add, expansion_search)
      end

    # Schedule auto-save if enabled
    if new_state.auto_save_interval > 0 do
      Process.send_after(self(), :auto_save, new_state.auto_save_interval)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:search, _query_int8, _k}, _from, %{initialized: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:search, _query_int8, _k}, _from, %{vector_count: count} = state)
      when count < @hnsw_threshold do
    {:reply, {:error, :below_threshold}, state}
  end

  def handle_call({:search, query_int8, k}, _from, state) do
    result = Math.hnsw_search(state.index, query_int8, k)
    {:reply, result, state}
  end

  def handle_call({:add, _key, _vector_int8}, _from, %{initialized: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:add, key, vector_int8}, _from, state) do
    case Math.hnsw_add(state.index, key, vector_int8) do
      {:ok, :ok} ->
        new_state = %{state | vector_count: state.vector_count + 1, dirty: true}
        {:reply, :ok, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:add_batch, _entries}, _from, %{initialized: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:add_batch, entries}, _from, state) do
    case Math.hnsw_add_batch(state.index, entries) do
      {:ok, count} ->
        new_state = %{state | vector_count: state.vector_count + count, dirty: true}
        {:reply, {:ok, count}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remove, _key}, _from, %{initialized: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:remove, key}, _from, state) do
    case Math.hnsw_remove(state.index, key) do
      {:ok, :ok} ->
        # Note: HNSW doesn't decrement size on remove, it marks as deleted
        new_state = %{state | dirty: true}
        {:reply, :ok, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:contains, _key}, _from, %{initialized: false} = state) do
    {:reply, false, state}
  end

  def handle_call({:contains, key}, _from, state) do
    case Math.hnsw_contains(state.index, key) do
      {:ok, exists} -> {:reply, exists, state}
      {:error, _} -> {:reply, false, state}
    end
  end

  def handle_call(:save, _from, %{initialized: false} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call(:save, _from, state) do
    case do_save(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:rebuild, _from, state) do
    case do_rebuild(state) do
      {:ok, count, new_state} -> {:reply, {:ok, count}, new_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      if state.initialized do
        case Math.hnsw_stats(state.index) do
          {:ok, nif_stats} ->
            Map.new(nif_stats)
            |> Map.put(:initialized, true)
            |> Map.put(:threshold, @hnsw_threshold)
            |> Map.put(:above_threshold, state.vector_count >= @hnsw_threshold)
            |> Map.put(:dirty, state.dirty)
            |> Map.put(:last_saved_at, state.last_saved_at)

          {:error, _} ->
            %{
              initialized: true,
              size: state.vector_count,
              dimensions: state.dimensions,
              threshold: @hnsw_threshold,
              above_threshold: state.vector_count >= @hnsw_threshold,
              dirty: state.dirty,
              last_saved_at: state.last_saved_at
            }
        end
      else
        %{
          initialized: false,
          size: 0,
          dimensions: state.dimensions,
          threshold: @hnsw_threshold,
          above_threshold: false
        }
      end

    {:reply, stats, state}
  end

  def handle_call(:should_use_hnsw, _from, state) do
    {:reply, state.initialized and state.vector_count >= @hnsw_threshold, state}
  end

  @impl true
  def handle_info(:auto_save, state) do
    new_state =
      if state.dirty and state.initialized do
        case do_save(state) do
          {:ok, saved_state} ->
            Logger.debug("HNSW index auto-saved")
            saved_state

          {:error, reason} ->
            Logger.warning("HNSW index auto-save failed: #{inspect(reason)}")
            state
        end
      else
        state
      end

    # Schedule next auto-save
    if new_state.auto_save_interval > 0 do
      Process.send_after(self(), :auto_save, new_state.auto_save_interval)
    end

    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.dirty and state.initialized do
      Logger.info("Saving HNSW index on shutdown")
      do_save(state)
    end

    :ok
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp create_new_index(state, connectivity, expansion_add, expansion_search) do
    case Math.hnsw_new(state.dimensions, connectivity, expansion_add, expansion_search) do
      {:ok, index} ->
        %{state | index: index, initialized: true, vector_count: 0}

      {:error, reason} ->
        Logger.error("Failed to create HNSW index: #{inspect(reason)}")
        %{state | initialized: false}
    end
  end

  defp do_save(state) do
    # Ensure directory exists
    dir = Path.dirname(state.index_path)
    File.mkdir_p!(dir)

    case Math.hnsw_save(state.index, state.index_path) do
      {:ok, :ok} ->
        {:ok, %{state | dirty: false, last_saved_at: DateTime.utc_now()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_rebuild(state) do
    Logger.info("Rebuilding HNSW index from database...")

    # Count total engrams with embeddings
    total_count =
      from(e in Engram, where: not is_nil(e.embedding_int8), select: count())
      |> Repo.one()

    Logger.info("Found #{total_count} engrams with embeddings")

    if total_count == 0 do
      {:ok, 0, state}
    else
      # Get config for new index
      config = Application.get_env(:mimo_mcp, __MODULE__, [])
      connectivity = Keyword.get(config, :connectivity, @default_connectivity)
      expansion_add = Keyword.get(config, :expansion_add, @default_expansion_add)
      expansion_search = Keyword.get(config, :expansion_search, @default_expansion_search)

      # Create new index with pre-reserved capacity
      case Math.hnsw_new(state.dimensions, connectivity, expansion_add, expansion_search) do
        {:ok, new_index} ->
          # Reserve capacity
          Math.hnsw_reserve(new_index, total_count)

          # Stream engrams in batches
          batch_size = 1000
          added = stream_rebuild(new_index, batch_size, total_count)

          Logger.info("HNSW index rebuilt with #{added} vectors")

          new_state = %{
            state
            | index: new_index,
              vector_count: added,
              dirty: true,
              initialized: true
          }

          # Save the rebuilt index
          case do_save(new_state) do
            {:ok, saved_state} -> {:ok, added, saved_state}
            {:error, _} -> {:ok, added, new_state}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp stream_rebuild(index, batch_size, total) do
    from(e in Engram,
      where: not is_nil(e.embedding_int8),
      select: {e.id, e.embedding_int8},
      order_by: [asc: e.id]
    )
    |> Repo.stream(max_rows: batch_size)
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      case Math.hnsw_add_batch(index, batch) do
        {:ok, count} ->
          progress = (acc + count) * 100 / total

          Logger.info(
            "HNSW rebuild progress: #{Float.round(progress, 1)}% (#{acc + count}/#{total})"
          )

          acc + count

        {:error, reason} ->
          Logger.warning("HNSW batch add failed: #{inspect(reason)}")
          acc
      end
    end)
  end
end
