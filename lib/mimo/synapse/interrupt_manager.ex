defmodule Mimo.Synapse.InterruptManager do
  @moduledoc """
  Manages execution interruption signals.
  
  Allows clients to interrupt long-running queries or procedures
  by signaling the executing process.
  """
  use GenServer

  require Logger

  @table :synapse_interrupts

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a process as interruptible by reference.
  """
  @spec register(String.t(), pid()) :: :ok
  def register(ref, pid) when is_binary(ref) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, ref, pid})
  end

  @doc """
  Unregisters an interruptible process.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(ref) when is_binary(ref) do
    GenServer.cast(__MODULE__, {:unregister, ref})
  end

  @doc """
  Signals an interrupt to a registered process.
  """
  @spec signal(String.t(), atom(), map()) :: :ok | {:error, :not_found}
  def signal(ref, signal_type, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:signal, ref, signal_type, metadata})
  end

  @doc """
  Checks if a reference has a pending interrupt.
  
  Should be called periodically by long-running processes.
  """
  @spec check_interrupt(String.t()) :: :ok | {:interrupt, atom(), map()}
  def check_interrupt(ref) do
    case :ets.lookup(@table, {:pending, ref}) do
      [{_, signal_type, metadata}] ->
        :ets.delete(@table, {:pending, ref})
        {:interrupt, signal_type, metadata}

      [] ->
        :ok
    end
  end

  @doc """
  Macro for checking interrupts in a loop.
  
  Usage:
  
      import Mimo.Synapse.InterruptManager, only: [interruptible: 2]
      
      interruptible ref do
        # Long-running work
        Process.sleep(100)
      end
  """
  defmacro interruptible(ref, do: block) do
    quote do
      case Mimo.Synapse.InterruptManager.check_interrupt(unquote(ref)) do
        :ok ->
          unquote(block)

        {:interrupt, _type, _meta} ->
          throw(:interrupt)
      end
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("✅ Synapse Interrupt Manager initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, ref, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    :ets.insert(@table, {{:process, ref}, pid, monitor_ref})
    {:reply, :ok, Map.put(state, monitor_ref, ref)}
  end

  @impl true
  def handle_call({:signal, ref, signal_type, metadata}, _from, state) do
    case :ets.lookup(@table, {:process, ref}) do
      [{{:process, ^ref}, pid, _monitor_ref}] ->
        # Store pending interrupt
        :ets.insert(@table, {{:pending, ref}, signal_type, metadata})

        # Also send direct message to process
        send(pid, {:interrupt_signal, signal_type, metadata})

        Logger.debug("Interrupt signaled for ref #{ref}: #{signal_type}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    case :ets.lookup(@table, {:process, ref}) do
      [{{:process, ^ref}, _pid, monitor_ref}] ->
        Process.demonitor(monitor_ref, [:flush])
        :ets.delete(@table, {:process, ref})
        :ets.delete(@table, {:pending, ref})
        {:noreply, Map.delete(state, monitor_ref)}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.get(state, monitor_ref) do
      nil ->
        {:noreply, state}

      ref ->
        :ets.delete(@table, {:process, ref})
        :ets.delete(@table, {:pending, ref})
        {:noreply, Map.delete(state, monitor_ref)}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
