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
  alias Mimo.Brain.Engram
  alias Mimo.Synapse.{GraphEdge, GraphNode}
  # Base weight increase per co-activation
  @ltp_increment 0.05
  # Initial weight for new edges
  @initial_weight 0.3
  # Minimum importance to create hebbian edges (prevents garbage edge creation)
  @min_importance_for_edge 0.5
  # Edge type for memory associations
  @edge_type :relates_to
  # Batch size for edge updates
  @batch_size 50

  # Learning-driven associations (Phase 3 Learning Loop)
  # These are stronger than co-activation because they represent actual success
  @outcome_initial_weight 0.5
  @outcome_ltp_increment 0.1

  # Rate limiting configuration helper (SPEC-088)
  defp max_edges_per_hour do
    Application.get_env(:mimo_mcp, :hebbian_learning, [])
    |> Keyword.get(:max_edges_per_hour, 500)
  end

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

  @impl true
  def init(_opts) do
    # Attach to co-activation telemetry events
    :telemetry.attach(
      "hebbian-learner",
      [:mimo, :memory, :coactivation],
      &__MODULE__.handle_coactivation/4,
      nil
    )

    # SPEC-087 Phase 3: Attach to learning outcome events from FeedbackBridge
    # This creates stronger associations between memories that led to success
    :telemetry.attach(
      "hebbian-learner-outcome",
      [:mimo, :learning, :outcome],
      &__MODULE__.handle_learning_outcome/4,
      nil
    )

    state = %{
      edges_created: 0,
      edges_strengthened: 0,
      pending_pairs: MapSet.new(),
      # Rate limiting (SPEC-088)
      edges_this_hour: 0,
      hour_started_at: System.monotonic_time(:second),
      rate_limited_pairs: 0,
      # Phase 3: Learning-driven edge stats
      outcome_edges_created: 0,
      outcome_edges_strengthened: 0
    }

    Logger.info(
      "HebbianLearner initialized - listening for co-activation and learning outcome events"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      edges_created: state.edges_created,
      edges_strengthened: state.edges_strengthened,
      pending_pairs: MapSet.size(state.pending_pairs),
      # Rate limiting stats (SPEC-088)
      edges_this_hour: state.edges_this_hour,
      max_edges_per_hour: max_edges_per_hour(),
      rate_limited_pairs: state.rate_limited_pairs,
      # Phase 3: Learning-driven edge stats
      outcome_edges_created: state.outcome_edges_created,
      outcome_edges_strengthened: state.outcome_edges_strengthened
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

  # Phase 3: Handle learning outcome coactivation with stronger weights
  @impl true
  def handle_cast({:outcome_coactivation, memory_ids, success}, state) do
    if success and length(memory_ids) >= 2 do
      # Generate pairs from memory_ids (limit to prevent explosion)
      limited_ids = Enum.take(memory_ids, 10)
      pairs = generate_pairs(limited_ids)

      # Process immediately with stronger weights (learning-driven)
      {created, strengthened} = strengthen_outcome_edges(pairs)

      new_state = %{
        state
        | outcome_edges_created: state.outcome_edges_created + created,
          outcome_edges_strengthened: state.outcome_edges_strengthened + strengthened,
          edges_this_hour: state.edges_this_hour + created
      }

      if created > 0 or strengthened > 0 do
        Logger.debug(
          "[HebbianLearner] Learning outcome: created #{created}, strengthened #{strengthened} edges from successful execution"
        )
      end

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = process_pending_pairs(state)
    {:noreply, new_state}
  end

  @doc false
  def handle_coactivation(_event, _measurements, metadata, _config) do
    pairs = Map.get(metadata, :pairs, [])

    if pairs != [] do
      GenServer.cast(__MODULE__, {:coactivation, pairs})
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Phase 3 Learning Loop: Handle learning outcome telemetry from FeedbackBridge.

  When tool execution succeeds, strengthen edges between all memories that
  were retrieved for that session. This creates "winning combinations" that
  get stronger associations over time.
  """
  def handle_learning_outcome(_event, _measurements, metadata, _config) do
    success = Map.get(metadata, :success, false)
    memory_ids = Map.get(metadata, :memory_ids, [])

    if success and length(memory_ids) >= 2 do
      GenServer.cast(__MODULE__, {:outcome_coactivation, memory_ids, success})
    end
  catch
    :exit, _ -> :ok
  end

  # Generate all unique pairs from a list of IDs
  defp generate_pairs(ids) when length(ids) < 2, do: []

  defp generate_pairs(ids) do
    for i <- ids, j <- ids, i < j, do: {i, j}
  end

  defp process_pending_pairs(%{pending_pairs: pending} = state) when pending == %MapSet{} do
    state
  end

  defp process_pending_pairs(%{pending_pairs: pending} = state) do
    # Rate limiting (SPEC-088): Check and reset hour if needed
    state = maybe_reset_hour(state)

    # Check if we've hit the rate limit
    remaining = remaining_budget(state)

    if remaining <= 0 do
      # Rate limited - drop pairs and log warning
      dropped_count = MapSet.size(pending)

      Logger.warning(
        "HebbianLearner rate limited: #{state.edges_this_hour}/#{max_edges_per_hour()} edges this hour, dropping #{dropped_count} pairs"
      )

      :telemetry.execute(
        [:mimo, :hebbian, :rate_limited],
        %{dropped_pairs: dropped_count},
        %{}
      )

      %{
        state
        | pending_pairs: MapSet.new(),
          rate_limited_pairs: state.rate_limited_pairs + dropped_count
      }
    else
      # Process pairs up to remaining budget
      pairs = MapSet.to_list(pending)
      pairs_to_process = Enum.take(pairs, remaining)

      {created, strengthened} = strengthen_edges(pairs_to_process)

      Logger.debug("HebbianLearner: created #{created} edges, strengthened #{strengthened} edges")

      %{
        state
        | pending_pairs: MapSet.new(),
          edges_created: state.edges_created + created,
          edges_strengthened: state.edges_strengthened + strengthened,
          edges_this_hour: state.edges_this_hour + created
      }
    end
  end

  # Rate limiting helpers (SPEC-088)
  defp maybe_reset_hour(state) do
    now = System.monotonic_time(:second)

    if now - state.hour_started_at >= 3600 do
      Logger.debug("HebbianLearner: hourly rate limit reset")
      %{state | hour_started_at: now, edges_this_hour: 0}
    else
      state
    end
  end

  defp remaining_budget(state) do
    max(0, max_edges_per_hour() - state.edges_this_hour)
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

  # Phase 3: Strengthen edges from learning outcomes with higher weights
  defp strengthen_outcome_edges(pairs) do
    Enum.reduce(pairs, {0, 0}, fn {id1, id2}, {created, strengthened} ->
      case strengthen_outcome_edge(id1, id2) do
        :created -> {created + 1, strengthened}
        :strengthened -> {created, strengthened + 1}
        :error -> {created, strengthened}
      end
    end)
  end

  # Phase 3: Create/strengthen edge with learning-driven weights (stronger than co-activation)
  defp strengthen_outcome_edge(memory_id_1, memory_id_2) do
    # Only create edges for important memories
    with {:ok, imp1} <- get_memory_importance(memory_id_1),
         {:ok, imp2} <- get_memory_importance(memory_id_2),
         true <- imp1 >= @min_importance_for_edge and imp2 >= @min_importance_for_edge do
      node1_id = ensure_memory_node(memory_id_1)
      node2_id = ensure_memory_node(memory_id_2)

      if node1_id && node2_id do
        case find_edge(node1_id, node2_id) do
          nil ->
            # Create with higher initial weight (learning-driven)
            create_outcome_edge(node1_id, node2_id)

          edge ->
            # Apply stronger LTP (learning-driven)
            apply_outcome_ltp(edge)
        end
      else
        :error
      end
    else
      _ -> :error
    end
  rescue
    e ->
      Logger.debug("HebbianLearner outcome edge error: #{Exception.message(e)}")
      :error
  end

  defp create_outcome_edge(source_id, target_id) do
    case Repo.insert(%GraphEdge{
           source_node_id: source_id,
           target_node_id: target_id,
           edge_type: @edge_type,
           weight: @outcome_initial_weight,
           properties: %{
             "source" => "hebbian_learning_outcome",
             "ltp_count" => 1,
             "from_success" => true
           },
           source: "hebbian_learning"
         }) do
      {:ok, _} -> :created
      _ -> :error
    end
  end

  defp apply_outcome_ltp(edge) do
    # Stronger LTP for learning-driven associations
    current_weight = edge.weight || @outcome_initial_weight
    new_weight = min(1.0, current_weight + @outcome_ltp_increment * (1.0 - current_weight))

    ltp_count = get_in(edge.properties, ["ltp_count"]) || 0
    from_success = get_in(edge.properties, ["from_success"]) || false

    case Repo.update(
           GraphEdge.changeset(edge, %{
             weight: new_weight,
             properties:
               edge.properties
               |> Map.put("ltp_count", ltp_count + 1)
               |> Map.put("from_success", from_success or true),
             last_accessed_at: DateTime.utc_now()
           })
         ) do
      {:ok, _} -> :strengthened
      _ -> :error
    end
  end

  defp strengthen_edge(memory_id_1, memory_id_2) do
    # Only create edges for important memories to prevent garbage edge bloat
    # QUALITY GATE: Require BOTH memories to be important (not just one)
    with {:ok, imp1} <- get_memory_importance(memory_id_1),
         {:ok, imp2} <- get_memory_importance(memory_id_2),
         true <- imp1 >= @min_importance_for_edge and imp2 >= @min_importance_for_edge do
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
    else
      # Skip low-importance memory pairs
      _ -> :error
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

  defp get_memory_importance(memory_id) do
    case Repo.one(from(e in Engram, where: e.id == ^memory_id, select: e.importance)) do
      nil -> {:error, :not_found}
      importance -> {:ok, importance || 0.0}
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

  @doc """
  SPEC-092: Clean up stale Hebbian edges that have never been accessed.

  Removes edges created by Hebbian learning that have:
  - access_count = 0 (never used after creation)
  - Created more than `max_age_days` ago (default: 7 days)

  This prevents unbounded growth of the graph edges table.

  ## Options
    - `:max_age_days` - Only delete edges older than this (default: 7)
    - `:dry_run` - If true, return count without deleting (default: false)

  ## Returns
    - `{:ok, deleted_count}` - Number of edges deleted
    - `{:error, reason}` - If cleanup fails
  """
  @spec cleanup_stale_edges(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stale_edges(opts \\ []) do
    max_age_days = Keyword.get(opts, :max_age_days, 7)
    dry_run = Keyword.get(opts, :dry_run, false)

    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days, :day)

    query =
      from(e in GraphEdge,
        where:
          e.source == "hebbian_learning" and
            (is_nil(e.access_count) or e.access_count == 0) and
            e.inserted_at < ^cutoff
      )

    if dry_run do
      count = Repo.aggregate(query, :count)
      {:ok, count}
    else
      {deleted, _} = Repo.delete_all(query)
      Logger.info("[HebbianLearner] Cleaned up #{deleted} stale edges (age > #{max_age_days} days)")
      {:ok, deleted}
    end
  rescue
    e ->
      Logger.error("[HebbianLearner] Cleanup failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
