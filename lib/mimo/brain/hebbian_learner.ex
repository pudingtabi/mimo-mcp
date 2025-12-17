defmodule Mimo.Brain.HebbianLearner do
  @moduledoc """
  Implements Hebbian learning for memory associations.

  "Neurons that fire together, wire together" - Donald Hebb, 1949

  This module listens to co-activation events from AccessTracker and
  strengthens graph edges between memories that are accessed together.

  ## Neuroscience Foundation: Long-Term Potentiation (LTP)

  When memories are co-activated (accessed within a short time window):
  1. If no edge exists: Create one with initial weight
  2. If edge exists: Strengthen weight using LTP formula

  The weight increase follows a bounded growth model:
  - new_weight = min(1.0, old_weight + increment * (1 - old_weight))
  - This ensures weights approach but never exceed 1.0
  - Stronger connections grow more slowly (diminishing returns)

  ## Configuration

  - `@ltp_increment`: Base weight increase per co-activation (default: 0.05)
  - `@initial_weight`: Weight for newly created edges (default: 0.3)
  - `@edge_type`: Type of edge to create/strengthen (default: :relates_to)

  ## Integration

  This module automatically attaches to telemetry events from AccessTracker.
  No manual intervention required - just ensure both are in the supervision tree.

  ## Example

      # Co-activation events trigger edge strengthening automatically
      AccessTracker.track(memory_1)
      AccessTracker.track(memory_2)  # Creates/strengthens edge between 1 and 2
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Synapse.{GraphNode, GraphEdge}

  # ==========================================================================
  # LTP (Long-Term Potentiation) Parameters
  # ==========================================================================
  # Base weight increase per co-activation
  @ltp_increment 0.05
  # Initial weight for new edges
  @initial_weight 0.3
  # Edge type for memory associations
  @edge_type :relates_to
  # Batch size for edge updates
  @batch_size 50

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current learning statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Force processing of pending co-activation pairs.
  """
  def flush do
    GenServer.call(__MODULE__, :flush)
  catch
    :exit, _ -> :ok
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    # Attach to co-activation telemetry events
    :telemetry.attach(
      "hebbian-learner",
      [:mimo, :memory, :coactivation],
      &__MODULE__.handle_coactivation/4,
      nil
    )

    state = %{
      edges_created: 0,
      edges_strengthened: 0,
      pending_pairs: MapSet.new()
    }

    Logger.info("HebbianLearner initialized - listening for co-activation events")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      edges_created: state.edges_created,
      edges_strengthened: state.edges_strengthened,
      pending_pairs: MapSet.size(state.pending_pairs)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = process_pending_pairs(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:coactivation, pairs}, state) do
    # Add pairs to pending set (deduplicates automatically)
    new_pending = Enum.reduce(pairs, state.pending_pairs, &MapSet.put(&2, &1))

    # Process if batch is large enough
    new_state =
      if MapSet.size(new_pending) >= @batch_size do
        process_pending_pairs(%{state | pending_pairs: new_pending})
      else
        %{state | pending_pairs: new_pending}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = process_pending_pairs(state)
    {:noreply, new_state}
  end

  # ==========================================================================
  # Telemetry Handler
  # ==========================================================================

  @doc false
  def handle_coactivation(_event, _measurements, metadata, _config) do
    pairs = Map.get(metadata, :pairs, [])

    if pairs != [] do
      GenServer.cast(__MODULE__, {:coactivation, pairs})
    end
  catch
    :exit, _ -> :ok
  end

  # ==========================================================================
  # Private Implementation
  # ==========================================================================

  defp process_pending_pairs(%{pending_pairs: pending} = state) when pending == %MapSet{} do
    state
  end

  defp process_pending_pairs(%{pending_pairs: pending} = state) do
    pairs = MapSet.to_list(pending)

    {created, strengthened} = strengthen_edges(pairs)

    Logger.debug("HebbianLearner: created #{created} edges, strengthened #{strengthened} edges")

    %{
      state
      | pending_pairs: MapSet.new(),
        edges_created: state.edges_created + created,
        edges_strengthened: state.edges_strengthened + strengthened
    }
  end

  defp strengthen_edges(pairs) do
    # For each pair, find or create edge and strengthen
    Enum.reduce(pairs, {0, 0}, fn {id1, id2}, {created, strengthened} ->
      case strengthen_edge(id1, id2) do
        :created -> {created + 1, strengthened}
        :strengthened -> {created, strengthened + 1}
        :error -> {created, strengthened}
      end
    end)
  end

  defp strengthen_edge(memory_id_1, memory_id_2) do
    # First, ensure we have graph nodes for these memories
    node1_id = ensure_memory_node(memory_id_1)
    node2_id = ensure_memory_node(memory_id_2)

    if node1_id && node2_id do
      # Check if edge exists
      case find_edge(node1_id, node2_id) do
        nil ->
          # Create new edge with initial weight
          create_edge(node1_id, node2_id)

        edge ->
          # Strengthen existing edge using LTP formula
          apply_ltp(edge)
      end
    else
      :error
    end
  rescue
    e ->
      Logger.debug("HebbianLearner edge error: #{Exception.message(e)}")
      :error
  end

  defp ensure_memory_node(memory_id) do
    # Check if node exists for this memory
    node_name = "memory:#{memory_id}"

    case Repo.one(from(n in GraphNode, where: n.name == ^node_name, select: n.id)) do
      nil ->
        # Create node for this memory
        case Repo.insert(%GraphNode{
               node_type: :concept,
               name: node_name,
               properties: %{"memory_id" => memory_id, "source" => "hebbian_learning"}
             }) do
          {:ok, node} -> node.id
          _ -> nil
        end

      id ->
        id
    end
  end

  defp find_edge(source_id, target_id) do
    # Look for edge in either direction (symmetric relationship)
    Repo.one(
      from(e in GraphEdge,
        where:
          (e.source_node_id == ^source_id and e.target_node_id == ^target_id and
             e.edge_type == ^@edge_type) or
            (e.source_node_id == ^target_id and e.target_node_id == ^source_id and
               e.edge_type == ^@edge_type),
        limit: 1
      )
    )
  end

  defp create_edge(source_id, target_id) do
    case Repo.insert(%GraphEdge{
           source_node_id: source_id,
           target_node_id: target_id,
           edge_type: @edge_type,
           weight: @initial_weight,
           properties: %{"source" => "hebbian_learning", "ltp_count" => 1},
           source: "hebbian_learning"
         }) do
      {:ok, _} -> :created
      _ -> :error
    end
  end

  defp apply_ltp(edge) do
    # LTP formula: new_weight = old_weight + increment * (1 - old_weight)
    # This ensures bounded growth approaching 1.0
    current_weight = edge.weight || @initial_weight
    new_weight = min(1.0, current_weight + @ltp_increment * (1.0 - current_weight))

    # Increment LTP count in properties
    ltp_count = get_in(edge.properties, ["ltp_count"]) || 0

    case Repo.update(
           GraphEdge.changeset(edge, %{
             weight: new_weight,
             properties: Map.put(edge.properties || %{}, "ltp_count", ltp_count + 1),
             last_accessed_at: DateTime.utc_now()
           })
         ) do
      {:ok, _} -> :strengthened
      _ -> :error
    end
  end
end
