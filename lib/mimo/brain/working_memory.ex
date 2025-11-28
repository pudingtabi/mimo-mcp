defmodule Mimo.Brain.WorkingMemory do
  @moduledoc """
  Working Memory Buffer - short-lived in-memory storage for active context.

  Uses ETS for fast, concurrent access with automatic TTL expiration.
  Items are stored temporarily and can be consolidated to long-term memory.

  ## Configuration

      config :mimo_mcp, :working_memory,
        enabled: true,
        ttl_seconds: 600,           # 10 minutes default
        max_items: 100,             # Capacity limit
        cleanup_interval_ms: 30_000  # 30 seconds

  ## Examples

      # Store a memory
      {:ok, id} = WorkingMemory.store("User prefers dark mode", importance: 0.7)

      # Retrieve by ID
      {:ok, item} = WorkingMemory.get(id)

      # Get recent items
      recent = WorkingMemory.get_recent(10)

      # Mark for consolidation
      :ok = WorkingMemory.mark_for_consolidation(id)
  """
  use GenServer
  require Logger

  alias Mimo.Brain.WorkingMemoryItem

  @table_name :mimo_working_memory
  @default_max_items 100
  @default_ttl 600

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store content in working memory.

  ## Options

    * `:importance` - Importance score 0-1 (default: 0.5)
    * `:session_id` - Session identifier
    * `:source` - Source of the memory (e.g., "tool_call", "user")
    * `:tool_name` - Name of tool if from tool call
    * `:context` - Additional context map
    * `:ttl` - Custom TTL in seconds (overrides default)

  ## Returns

    * `{:ok, id}` - ID of stored item
    * `{:error, reason}` - On failure
  """
  @spec store(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def store(content, opts \\ []) when is_binary(content) do
    GenServer.call(__MODULE__, {:store, content, opts})
  end

  @doc """
  Retrieve an item by ID. Updates accessed_at timestamp.
  """
  @spec get(String.t()) :: {:ok, WorkingMemoryItem.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Get the N most recent items.
  """
  @spec get_recent(pos_integer()) :: [WorkingMemoryItem.t()]
  def get_recent(limit \\ 10) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:get_recent, limit})
  end

  @doc """
  Search working memory by content (simple text match).
  """
  @spec search(String.t(), keyword()) :: [WorkingMemoryItem.t()]
  def search(query, opts \\ []) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query, opts})
  end

  @doc """
  Mark an item as a consolidation candidate.
  """
  @spec mark_for_consolidation(String.t()) :: :ok | {:error, :not_found}
  def mark_for_consolidation(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:mark_for_consolidation, id})
  end

  @doc """
  Get all items marked for consolidation.
  """
  @spec get_consolidation_candidates() :: [WorkingMemoryItem.t()]
  def get_consolidation_candidates do
    GenServer.call(__MODULE__, :get_consolidation_candidates)
  end

  @doc """
  Delete a specific item.
  """
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Clear all items for a session.
  """
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:clear_session, session_id})
  end

  @doc """
  Clear all expired items. Returns count of removed items.
  """
  @spec clear_expired() :: {:ok, non_neg_integer()}
  def clear_expired do
    GenServer.call(__MODULE__, :clear_expired)
  end

  @doc """
  Get current statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clear all items (useful for testing).
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    # Create ETS table
    table =
      :ets.new(@table_name, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    state = %{
      table: table,
      count: 0,
      total_stored: 0,
      total_expired: 0,
      total_evicted: 0
    }

    Logger.info("Working Memory initialized")
    {:ok, state}
  end

  @impl true
  def handle_call({:store, content, opts}, _from, state) do
    max_items = get_config(:max_items, @default_max_items)

    # Check capacity and evict if needed
    state =
      if state.count >= max_items do
        evict_oldest(state)
      else
        state
      end

    # Build item attributes
    attrs = %{
      content: content,
      importance: Keyword.get(opts, :importance, 0.5),
      session_id: Keyword.get(opts, :session_id),
      source: Keyword.get(opts, :source, "unknown"),
      tool_name: Keyword.get(opts, :tool_name),
      context: Keyword.get(opts, :context, %{}),
      tokens: estimate_tokens(content)
    }

    case WorkingMemoryItem.new(attrs) do
      {:ok, item} ->
        # Custom TTL if provided
        item =
          case Keyword.get(opts, :ttl) do
            nil -> item
            ttl -> WorkingMemoryItem.extend_ttl(item, ttl)
          end

        # Store in ETS with key = {expires_at_unix, id} for efficient TTL cleanup
        expires_unix = DateTime.to_unix(item.expires_at, :microsecond)
        key = {expires_unix, item.id}
        :ets.insert(@table_name, {key, item})

        :telemetry.execute(
          [:mimo, :working_memory, :stored],
          %{count: 1},
          %{
            source: item.source,
            importance: item.importance,
            session_id: item.session_id
          }
        )

        new_state = %{state | count: state.count + 1, total_stored: state.total_stored + 1}
        {:reply, {:ok, item.id}, new_state}

      {:error, changeset} ->
        {:reply, {:error, changeset.errors}, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case find_by_id(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {key, item} ->
        # Update accessed_at
        updated_item = WorkingMemoryItem.touch(item)
        :ets.insert(@table_name, {key, updated_item})

        :telemetry.execute(
          [:mimo, :working_memory, :retrieved],
          %{count: 1},
          %{age_ms: age_in_ms(updated_item)}
        )

        {:reply, {:ok, updated_item}, state}
    end
  end

  @impl true
  def handle_call({:get_recent, limit}, _from, state) do
    # Get all items, sort by created_at desc, take limit
    items =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_key, item} -> item end)
      |> Enum.reject(&WorkingMemoryItem.expired?/1)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    query_lower = String.downcase(query)

    items =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_key, item} -> item end)
      |> Enum.reject(&WorkingMemoryItem.expired?/1)
      |> Enum.filter(fn item ->
        String.contains?(String.downcase(item.content), query_lower)
      end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:mark_for_consolidation, id}, _from, state) do
    case find_by_id(id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {key, item} ->
        updated_item = %{item | consolidation_candidate: true}
        :ets.insert(@table_name, {key, updated_item})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_consolidation_candidates, _from, state) do
    items =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_key, item} -> item end)
      |> Enum.filter(& &1.consolidation_candidate)
      |> Enum.reject(&WorkingMemoryItem.expired?/1)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case find_by_id(id) do
      nil ->
        {:reply, :ok, state}

      {key, _item} ->
        :ets.delete(@table_name, key)
        {:reply, :ok, %{state | count: max(0, state.count - 1)}}
    end
  end

  @impl true
  def handle_call({:clear_session, session_id}, _from, state) do
    deleted =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_key, item} -> item.session_id == session_id end)
      |> Enum.map(fn {key, _item} ->
        :ets.delete(@table_name, key)
        1
      end)
      |> Enum.sum()

    {:reply, :ok, %{state | count: max(0, state.count - deleted)}}
  end

  @impl true
  def handle_call(:clear_expired, _from, state) do
    now_unix = DateTime.to_unix(DateTime.utc_now(), :microsecond)

    # Delete all keys where expires_at < now
    deleted =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {{expires_unix, _id}, _item} -> expires_unix < now_unix end)
      |> Enum.map(fn {key, _item} ->
        :ets.delete(@table_name, key)
        1
      end)
      |> Enum.sum()

    if deleted > 0 do
      :telemetry.execute(
        [:mimo, :working_memory, :expired],
        %{count: deleted},
        %{}
      )
    end

    new_state = %{
      state
      | count: max(0, state.count - deleted),
        total_expired: state.total_expired + deleted
    }

    {:reply, {:ok, deleted}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      count: state.count,
      total_stored: state.total_stored,
      total_expired: state.total_expired,
      total_evicted: state.total_evicted,
      max_items: get_config(:max_items, @default_max_items),
      ttl_seconds: get_config(:ttl_seconds, @default_ttl)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, %{state | count: 0}}
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp find_by_id(id) do
    :ets.tab2list(@table_name)
    |> Enum.find(fn {_key, item} -> item.id == id end)
  end

  defp evict_oldest(state) do
    # Get the oldest item (first in ordered_set by expires_at)
    case :ets.first(@table_name) do
      :"$end_of_table" ->
        state

      key ->
        :ets.delete(@table_name, key)

        :telemetry.execute(
          [:mimo, :working_memory, :evicted],
          %{count: 1},
          %{reason: :capacity}
        )

        %{state | count: max(0, state.count - 1), total_evicted: state.total_evicted + 1}
    end
  end

  defp estimate_tokens(content) do
    # Rough estimate: ~4 characters per token
    div(String.length(content), 4)
  end

  defp age_in_ms(%{created_at: created_at}) do
    DateTime.diff(DateTime.utc_now(), created_at, :millisecond)
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :working_memory, [])
    |> Keyword.get(key, default)
  end
end
