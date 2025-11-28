defmodule Mimo.SemanticStore.InferenceEngine do
  @moduledoc """
  Forward/backward chaining inference over semantic triples.

  Applies inference rules to derive new facts from existing triples.
  Uses in-memory :digraph for fast pathfinding during inference.

  ## Rule Types

  - **Transitivity**: If A→B and B→C, then A→C
  - **Symmetry**: If A→B, then B→A
  - **Inverse**: If A reports_to B, then B manages A

  ## Usage

      # Apply transitive inference
      {:ok, new_triples} = InferenceEngine.forward_chain("reports_to")
      
      # Materialize all inferred paths
      InferenceEngine.materialize_paths("reports_to")
  """

  alias Mimo.SemanticStore.{Triple, Repository, Predicates}
  alias Mimo.Repo

  import Ecto.Query
  require Logger

  @doc """
  Forward chaining inference: derive new facts from existing ones.

  ## Parameters

    - `predicate` - The predicate to apply inference rules to
    - `opts` - Options:
      - `:max_depth` - Maximum inference depth (default: 3)
      - `:min_confidence` - Minimum confidence for base facts (default: 0.8)
      - `:confidence_decay` - Confidence reduction per hop (default: 0.1)
      - `:persist` - Whether to save inferred triples (default: false)

  ## Returns

    - `{:ok, inferred_triples}` - List of newly inferred triples
  """
  @spec forward_chain(String.t(), keyword()) :: {:ok, [map()]}
  def forward_chain(predicate, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 3)
    min_confidence = Keyword.get(opts, :min_confidence, 0.8)
    confidence_decay = Keyword.get(opts, :confidence_decay, 0.1)
    persist = Keyword.get(opts, :persist, false)

    unless Predicates.transitive?(predicate) do
      Logger.warning("Predicate '#{predicate}' is not marked as transitive")
    end

    # Build in-memory graph
    graph = build_digraph(predicate, min_confidence)

    # Find all transitive closures
    inferred =
      :digraph.vertices(graph)
      |> Enum.flat_map(fn vertex ->
        find_transitive_paths(graph, vertex, max_depth)
      end)
      |> Enum.map(fn {from, to, depth} ->
        confidence = max(0.0, 1.0 - depth * confidence_decay)

        %{
          subject_id: elem(from, 0),
          subject_type: elem(from, 1),
          predicate: predicate,
          object_id: elem(to, 0),
          object_type: elem(to, 1),
          confidence: confidence,
          source: "inference:transitive:depth=#{depth}",
          metadata: %{inferred: true, depth: depth}
        }
      end)
      |> filter_existing_triples()

    # Cleanup graph
    :digraph.delete(graph)

    # Optionally persist
    if persist and length(inferred) > 0 do
      {:ok, count} = Repository.batch_create(inferred)
      Logger.info("Persisted #{count} inferred triples for '#{predicate}'")
    end

    {:ok, inferred}
  end

  @doc """
  Backward chaining: given a goal, find supporting facts.

  ## Parameters

    - `goal` - The fact to prove as `{subject_id, predicate, object_id}`
    - `opts` - Options:
      - `:max_depth` - Maximum search depth

  ## Returns

    - `{:ok, proof}` - Proof tree if goal can be derived
    - `{:error, :unprovable}` - Goal cannot be proven
  """
  @spec backward_chain({String.t(), String.t(), String.t()}, keyword()) ::
          {:ok, map()} | {:error, :unprovable}
  def backward_chain({subject_id, predicate, object_id}, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 5)

    # Check if fact exists directly
    direct_match =
      from(t in Triple,
        where:
          t.subject_id == ^subject_id and
            t.predicate == ^predicate and
            t.object_id == ^object_id,
        limit: 1
      )
      |> Repo.one()

    if direct_match do
      {:ok,
       %{
         goal: {subject_id, predicate, object_id},
         proof_type: :direct,
         confidence: direct_match.confidence,
         supporting_facts: [direct_match]
       }}
    else
      # Try to prove via transitive chain
      find_proof_chain(subject_id, predicate, object_id, max_depth)
    end
  end

  @doc """
  Materializes all transitive paths for a predicate.

  Creates explicit triples for all inferred relationships,
  improving query performance at the cost of storage.
  """
  @spec materialize_paths(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def materialize_paths(predicate, opts \\ []) do
    {:ok, inferred} = forward_chain(predicate, Keyword.put(opts, :persist, false))

    if length(inferred) > 0 do
      Repository.batch_create(inferred)
    else
      {:ok, 0}
    end
  end

  @doc """
  Applies inverse predicate rules.

  For each triple `A predicate B`, creates `B inverse(predicate) A`.
  """
  @spec apply_inverse_rules(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def apply_inverse_rules(predicate, opts \\ []) do
    persist = Keyword.get(opts, :persist, false)

    case Predicates.inverse(predicate) do
      nil ->
        {:ok, 0}

      inverse_pred ->
        # Find all triples that don't have their inverse
        triples = Repository.get_by_predicate(predicate)

        inverse_triples =
          triples
          |> Enum.map(fn t ->
            %{
              subject_id: t.object_id,
              subject_type: t.object_type,
              predicate: inverse_pred,
              object_id: t.subject_id,
              object_type: t.subject_type,
              confidence: t.confidence,
              source: "inference:inverse:#{t.id}",
              metadata: %{inferred: true, inverse_of: t.id}
            }
          end)
          |> filter_existing_triples()

        if persist and length(inverse_triples) > 0 do
          Repository.batch_create(inverse_triples)
        else
          {:ok, length(inverse_triples)}
        end
    end
  end

  # Private functions

  defp build_digraph(predicate, min_confidence) do
    graph = :digraph.new([:acyclic])

    triples =
      from(t in Triple,
        where: t.predicate == ^predicate and t.confidence >= ^min_confidence
      )
      |> Repo.all()

    # Add vertices and edges
    Enum.each(triples, fn t ->
      from_vertex = {t.subject_id, t.subject_type}
      to_vertex = {t.object_id, t.object_type}

      :digraph.add_vertex(graph, from_vertex)
      :digraph.add_vertex(graph, to_vertex)
      :digraph.add_edge(graph, from_vertex, to_vertex, t.confidence)
    end)

    graph
  end

  defp find_transitive_paths(graph, start_vertex, max_depth) do
    # BFS to find all reachable vertices with depth
    bfs_traverse(graph, start_vertex, max_depth, %{start_vertex => 0}, [])
    |> Enum.filter(fn {from, _to, depth} ->
      # Only keep actual transitive inferences
      from == start_vertex and depth > 1
    end)
  end

  defp bfs_traverse(_graph, _current, _max_depth, visited, acc) when map_size(visited) > 1000 do
    # Safety limit
    acc
  end

  defp bfs_traverse(graph, current, max_depth, visited, acc) do
    current_depth = Map.get(visited, current, 0)

    if current_depth >= max_depth do
      acc
    else
      # Get direct neighbors
      neighbors = :digraph.out_neighbours(graph, current)

      {_new_visited, new_acc} =
        Enum.reduce(neighbors, {visited, acc}, fn neighbor, {vis, a} ->
          if Map.has_key?(vis, neighbor) do
            {vis, a}
          else
            depth = current_depth + 1
            new_vis = Map.put(vis, neighbor, depth)

            # Get the start vertex (first vertex with depth 0)
            start = Enum.find(vis, fn {_v, d} -> d == 0 end) |> elem(0)

            new_a =
              if depth > 1 do
                [{start, neighbor, depth} | a]
              else
                a
              end

            # Continue BFS - recurse and get back updated state
            recursive_acc = bfs_traverse(graph, neighbor, max_depth, new_vis, new_a)
            {new_vis, recursive_acc}
          end
        end)

      new_acc
    end
  end

  defp find_proof_chain(subject_id, predicate, object_id, max_depth) do
    # Use Query module's path finding
    case Mimo.SemanticStore.Query.find_path(subject_id, object_id, predicate, max_depth: max_depth) do
      {:ok, path} when length(path) > 2 ->
        # Build proof from path
        confidence = :math.pow(0.9, length(path) - 1)

        {:ok,
         %{
           goal: {subject_id, predicate, object_id},
           proof_type: :transitive,
           confidence: Float.round(confidence, 3),
           path: path,
           # Would need to fetch actual triples
           supporting_facts: []
         }}

      _ ->
        {:error, :unprovable}
    end
  end

  defp filter_existing_triples(triples) do
    # Filter out triples that already exist
    Enum.reject(triples, fn t ->
      existing =
        from(tr in Triple,
          where:
            tr.subject_id == ^t.subject_id and
              tr.predicate == ^t.predicate and
              tr.object_id == ^t.object_id,
          limit: 1
        )
        |> Repo.one()

      existing != nil
    end)
  end
end
