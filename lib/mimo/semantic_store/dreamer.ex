defmodule Mimo.SemanticStore.Dreamer do
  @moduledoc """
  Async background inference GenServer ("The Dreamer").

  Runs inference passes in the background to derive new facts from existing triples.
  Uses debouncing to prevent database contention during high-throughput writes.
  """

  use GenServer
  require Logger

  alias Mimo.SemanticStore.InferenceEngine
  alias Mimo.Repo
  alias Mimo.Sandbox

  @debounce_ms 500

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules an inference pass for the given graph.
  Debounced to prevent rapid re-triggering.
  """
  @spec schedule_inference(String.t()) :: :ok
  def schedule_inference(graph_id \\ "global") do
    GenServer.cast(__MODULE__, {:schedule, graph_id})
  end

  @doc """
  Forces immediate inference (bypasses debounce).
  Use sparingly.
  """
  @spec force_inference(String.t()) :: {:ok, map()} | {:error, term()}
  def force_inference(graph_id \\ "global") do
    GenServer.call(__MODULE__, {:force, graph_id}, 30_000)
  end

  @doc """
  Returns current inference queue status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ==========================================================================
  # Server Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    state = %{
      pending_graphs: MapSet.new(),
      timers: %{},
      stats: %{
        passes_completed: 0,
        triples_inferred: 0,
        last_run: nil
      }
    }

    Logger.info("Dreamer started - background inference enabled")
    {:ok, state}
  end

  @impl true
  def handle_cast({:schedule, graph_id}, state) do
    # Cancel existing timer for this graph
    state = cancel_timer(state, graph_id)

    # Schedule new debounced inference
    timer_ref = Process.send_after(self(), {:run_inference, graph_id}, @debounce_ms)

    new_state = %{
      state
      | pending_graphs: MapSet.put(state.pending_graphs, graph_id),
        timers: Map.put(state.timers, graph_id, timer_ref)
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:force, graph_id}, _from, state) do
    state = cancel_timer(state, graph_id)

    case run_inference_pass(graph_id) do
      {:ok, result} ->
        new_state = update_stats(state, result)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      pending_graphs: MapSet.to_list(state.pending_graphs),
      stats: state.stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:run_inference, graph_id}, state) do
    Logger.debug("Running scheduled inference for graph: #{graph_id}")

    new_state = %{
      state
      | pending_graphs: MapSet.delete(state.pending_graphs, graph_id),
        timers: Map.delete(state.timers, graph_id)
    }

    start_time = System.monotonic_time(:millisecond)

    case run_inference_pass(graph_id) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.info("Inference completed: #{result.triples_created} new triples")

        # Emit telemetry
        :telemetry.execute(
          [:mimo, :semantic_store, :inference],
          %{duration_ms: duration_ms},
          %{triples_created: result.triples_created, graph_id: graph_id}
        )

        send(self(), {:inference_completed, result})
        {:noreply, update_stats(new_state, result)}

      {:error, reason} ->
        Logger.warning("Inference failed: #{inspect(reason)}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:inference_completed, _result}, state) do
    # Hook for tests and observers
    {:noreply, state}
  end

  @impl true
  def handle_info({:inference_triggered, _graph_id}, state) do
    # Hook for tests
    {:noreply, state}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp cancel_timer(state, graph_id) do
    case Map.get(state.timers, graph_id) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | timers: Map.delete(state.timers, graph_id)}
    end
  end

  defp run_inference_pass(graph_id) do
    # Skip if running in test mode with sandbox - we don't have DB access
    if Sandbox.sandbox_mode?() do
      Logger.debug("Dreamer: Skipping inference in sandbox mode")

      {:ok,
       %{
         graph_id: graph_id,
         triples_created: 0,
         by_predicate: %{},
         inverse_created: 0,
         timestamp: DateTime.utc_now()
       }}
    else
      do_run_inference_pass(graph_id)
    end
  end

  defp do_run_inference_pass(graph_id) do
    # Run inside transaction with configurable mode
    Repo.transaction(
      fn ->
        # Get transitive predicates
        predicates = ["depends_on", "reports_to", "contains", "belongs_to", "subclass_of"]

        results =
          Enum.map(predicates, fn predicate ->
            case InferenceEngine.forward_chain(predicate,
                   max_depth: 3,
                   persist: true,
                   graph_id: graph_id
                 ) do
              {:ok, inferred} -> length(inferred)
            end
          end)

        # Apply inverse rules
        inverse_count = apply_inverse_rules(graph_id)

        total = Enum.sum(results) + inverse_count

        %{
          graph_id: graph_id,
          triples_created: total,
          by_predicate: Enum.zip(predicates, results) |> Map.new(),
          inverse_created: inverse_count,
          timestamp: DateTime.utc_now()
        }
      end,
      transaction_opts()
    )
  end

  # Configurable transaction options based on database adapter
  defp transaction_opts do
    case Application.get_env(:mimo_mcp, :database_adapter, :sqlite) do
      :sqlite -> [mode: :immediate, timeout: 30_000]
      :postgres -> [timeout: 30_000]
      _ -> [timeout: 30_000]
    end
  end

  defp apply_inverse_rules(graph_id) do
    inverse_pairs = [
      {"reports_to", "manages"},
      {"contains", "belongs_to"},
      {"owns", "owned_by"}
    ]

    Enum.reduce(inverse_pairs, 0, fn {pred, _inverse}, acc ->
      case InferenceEngine.apply_inverse_rules(pred, persist: true, graph_id: graph_id) do
        {:ok, count} -> acc + count
        _ -> acc
      end
    end)
  end

  defp update_stats(state, result) do
    %{
      state
      | stats: %{
          passes_completed: state.stats.passes_completed + 1,
          triples_inferred: state.stats.triples_inferred + result.triples_created,
          last_run: result.timestamp
        }
    }
  end
end
