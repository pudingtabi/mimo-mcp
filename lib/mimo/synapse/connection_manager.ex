defmodule Mimo.Synapse.ConnectionManager do
  @moduledoc """
  Manages WebSocket connection lifecycle for agents.

  Tracks active connections, handles reconnection logic,
  and provides connection health monitoring.
  """
  use GenServer

  alias Phoenix.PubSub
  require Logger

  @table :synapse_connections

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Tracks a new agent connection.
  """
  @spec track(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def track(agent_id, channel_pid) do
    GenServer.call(__MODULE__, {:track, agent_id, channel_pid})
  end

  @doc """
  Removes an agent connection.
  """
  @spec untrack(String.t()) :: :ok
  def untrack(agent_id) do
    GenServer.cast(__MODULE__, {:untrack, agent_id})
  end

  @doc """
  Gets the channel PID for an agent.
  """
  @spec get(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, pid, _meta}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active agent connections.
  """
  @spec list_active() :: [{String.t(), pid(), map()}]
  def list_active do
    :ets.tab2list(@table)
  end

  @doc """
  Returns count of active connections.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Broadcasts a message to a specific agent.
  """
  @spec send_to_agent(String.t(), String.t(), map()) :: :ok | {:error, :not_connected}
  def send_to_agent(agent_id, event, payload) do
    PubSub.broadcast(Mimo.PubSub, "agent:#{agent_id}", %{
      event: event,
      payload: payload
    })
  end

  @doc """
  Broadcasts a message to all connected agents.
  """
  @spec broadcast_all(String.t(), map()) :: :ok
  def broadcast_all(event, payload) do
    list_active()
    |> Enum.each(fn {agent_id, _pid, _meta} ->
      send_to_agent(agent_id, event, payload)
    end)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for connection tracking
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    Logger.info("✅ Synapse Connection Manager initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:track, agent_id, channel_pid}, _from, state) do
    # Monitor the channel process
    ref = Process.monitor(channel_pid)

    meta = %{
      connected_at: System.system_time(:millisecond),
      monitor_ref: ref
    }

    # Store in ETS
    :ets.insert(@table, {agent_id, channel_pid, meta})

    # Subscribe to agent topic
    PubSub.subscribe(Mimo.PubSub, "agent:#{agent_id}")

    Logger.debug("Tracked agent connection: #{agent_id}")
    {:reply, {:ok, channel_pid}, Map.put(state, ref, agent_id)}
  end

  @impl true
  def handle_cast({:untrack, agent_id}, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, _pid, %{monitor_ref: ref}}] ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table, agent_id)
        PubSub.unsubscribe(Mimo.PubSub, "agent:#{agent_id}")
        Logger.debug("Untracked agent connection: #{agent_id}")
        {:noreply, Map.delete(state, ref)}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        :ets.delete(@table, agent_id)
        Logger.info("Agent #{agent_id} disconnected: #{inspect(reason)}")
        {:noreply, Map.delete(state, ref)}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
