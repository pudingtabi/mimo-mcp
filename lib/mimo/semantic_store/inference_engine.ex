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

  alias RuleGenerator
  alias Mimo.Repo
  alias Mimo.SemanticStore.{Predicates, Repository, Triple}

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

    # Find all transitive closures (symbolic inference)
    symbolic_inferred =
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

    # Neuro-symbolic extension (LLM rules + GNN predictions)
    neuro_symbolic_inferred =
      if Keyword.get(opts, :neuro_symbolic, true) do
        try do
          forward_chain_neuro_symbolic(predicate, opts)
        rescue
          e ->
            Logger.error("Neuro-symbolic forward chain failed: #{inspect(e)}")
            []
        end
      else
        []
      end

    # Merge and deduplicate
    # Prefer neuro-symbolic inferences over purely symbolic ones when deduplicating
    inferred =
      (neuro_symbolic_inferred ++ symbolic_inferred)
      |> Enum.uniq_by(fn t -> {t.subject_id, t.predicate, t.object_id} end)

    # Cleanup graph
    :digraph.delete(graph)

    # Optionally persist
    if persist and inferred != [] do
      {:ok, count} = Repository.batch_create(inferred)
      Logger.info("Persisted #{count} inferred triples for '#{predicate}'")
    end

    {:ok, inferred}
  end

  defp forward_chain_neuro_symbolic(predicate, opts) do
    max_depth = Keyword.get(opts, :max_depth, 3)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # STEP 1: Query existing validated rules from the database for this predicate
    existing_rules = query_existing_rules_for_predicate(predicate)

    # STEP 2: Apply existing rules first
    inferred_from_existing =
      existing_rules
      |> Enum.flat_map(fn rule ->
        apply_rule_for_inference(rule, predicate, max_depth, min_confidence, opts)
      end)

    # STEP 3: If we have results from existing rules, return them
    # Otherwise, try LLM rule generation as fallback
    if inferred_from_existing != [] do
      inferred_from_existing
    else
      # Try to discover LLM rules for this predicate (best-effort)
      # Use generate_and_persist_rules so we get back persisted Rule structs when requested
      rs_opts = [max_rules: 3, persist_validated: Keyword.get(opts, :persist_rules, false)]

      case Mimo.NeuroSymbolic.RuleGenerator.generate_and_persist_rules(
             "Infer rules for '#{predicate}'",
             rs_opts
           ) do
        {:ok, %{persisted: persisted, candidates: _candidates, others: _others}} ->
          relevant_rules = persisted

          relevant_rules
          |> Enum.filter(fn r -> (r.confidence || 0.0) >= 0.0 end)
          |> Enum.flat_map(fn rule ->
            apply_rule_for_inference(rule, predicate, max_depth, min_confidence, opts)
          end)

        {:ok, %{candidates: candidates}} ->
          # If nothing was persisted, use candidates list (no persisted id)
          candidates
          |> Enum.filter(&(&1.confidence >= 0.0))
          |> Enum.flat_map(fn rule ->
            apply_rule_for_inference(rule, predicate, max_depth, min_confidence, opts)
          end)

        {:error, _} ->
          []
      end
    end
  end

  # Query existing validated rules from the database that match this predicate
  defp query_existing_rules_for_predicate(predicate) do
    alias Mimo.NeuroSymbolic.Rule

    # Query rules with validated status and conclusion matching the predicate
    # The conclusion can be either the predicate string directly or a JSON object with "predicate" key
    predicate_str = to_string(predicate)
    predicate_pattern = "%\"predicate\":\"#{predicate_str}\"%"

    from(r in Rule,
      where:
        r.validation_status == "validated" and
          (r.conclusion == ^predicate_str or like(r.conclusion, ^predicate_pattern)),
      order_by: [desc: r.confidence]
    )
    |> Mimo.Repo.all()
  end

  # Apply a rule to infer transitive triples, returning results with inferred_by_rule_id
  defp apply_rule_for_inference(rule, predicate, max_depth, min_confidence, opts) do
    rule_id = get_rule_field(rule, :id)
    rule_conf = get_rule_field(rule, :confidence) || 0.5
    conclusion_pred = extract_conclusion_predicate(rule)

    if to_string(conclusion_pred) == to_string(predicate) do
      graph = build_digraph(predicate, min_confidence)

      inferred =
        :digraph.vertices(graph)
        |> Enum.flat_map(fn vertex ->
          find_transitive_paths(graph, vertex, max_depth)
        end)
        |> Enum.map(fn {from, to, depth} ->
          build_inferred_triple(from, to, depth, predicate, rule_id, rule_conf, opts)
        end)
        |> filter_existing_triples()

      :digraph.delete(graph)
      inferred
    else
      []
    end
  end

  defp get_rule_field(rule, field) when is_map(rule) do
    Map.get(rule, field) || Map.get(rule, to_string(field))
  end

  defp get_rule_field(rule, field), do: Map.get(rule, field)

  defp extract_conclusion_predicate(rule) do
    conclusion_field = get_rule_field(rule, :conclusion)

    cond do
      is_map(conclusion_field) ->
        Map.get(conclusion_field, "predicate") || Map.get(conclusion_field, :predicate)

      is_binary(conclusion_field) ->
        parse_conclusion_predicate(conclusion_field)

      true ->
        conclusion_field
    end
  end

  defp parse_conclusion_predicate(json_str) do
    case Jason.decode(json_str) do
      {:ok, m} when is_map(m) -> Map.get(m, "predicate") || Map.get(m, :predicate)
      _ -> json_str
    end
  end

  defp build_inferred_triple(from, to, depth, predicate, rule_id, rule_conf, opts) do
    decay = Keyword.get(opts, :confidence_decay, 0.1)
    confidence = max(0.0, rule_conf * (1.0 - depth * decay))

    %{
      subject_id: elem(from, 0),
      subject_type: elem(from, 1),
      predicate: predicate,
      object_id: elem(to, 0),
      object_type: elem(to, 1),
      confidence: confidence,
      source: "neuro_symbolic:rule:#{rule_id}",
      metadata: %{inferred: true, depth: depth, rule_id: rule_id},
      inferred_by_rule_id: rule_id
    }
  end

  # End of file

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

    if inferred != [] do
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

        if persist and inverse_triples != [] do
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
      neighbors = :digraph.out_neighbours(graph, current)

      {_new_visited, new_acc} =
        Enum.reduce(neighbors, {visited, acc}, fn neighbor, {vis, a} ->
          process_bfs_neighbor(graph, neighbor, current_depth, max_depth, vis, a)
        end)

      new_acc
    end
  end

  defp process_bfs_neighbor(_graph, neighbor, _current_depth, _max_depth, vis, acc)
       when is_map_key(vis, neighbor) do
    {vis, acc}
  end

  defp process_bfs_neighbor(graph, neighbor, current_depth, max_depth, vis, acc) do
    depth = current_depth + 1
    new_vis = Map.put(vis, neighbor, depth)
    start = Enum.find(vis, fn {_v, d} -> d == 0 end) |> elem(0)
    new_acc = if depth > 1, do: [{start, neighbor, depth} | acc], else: acc
    recursive_acc = bfs_traverse(graph, neighbor, max_depth, new_vis, new_acc)
    {new_vis, recursive_acc}
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
           # Supporting facts require triple fetch (not included for performance).
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
