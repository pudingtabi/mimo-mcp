defmodule Mimo.Tools.Dispatchers.NeuroSymbolicInference do
  @moduledoc """
  Dispatcher for neuro-symbolic inference tool.

  Operations:
  - discover_rules - Generate and persist logical rules from prompts
  - link_modalities - Link entities across modalities (code, memory, knowledge)
  - train_clusters - Train k-means clusters on memory embeddings
  - predict_links - Predict related memories based on embedding similarity
  - cluster_memories - Get cluster assignments for memories
  """
  require Logger
  alias Mimo.NeuroSymbolic.{CrossModalityLinker, GnnPredictor, RuleGenerator}

  @operations [
    "discover_rules",
    "link_modalities",
    "train_clusters",
    "predict_links",
    "cluster_memories",
    # Legacy alias
    "train_gnn"
  ]

  def dispatch(args) do
    op = args["operation"] || "discover_rules"

    case op do
      "discover_rules" ->
        dispatch_discover_rules(args)

      "link_modalities" ->
        dispatch_link_modalities(args)

      "train_clusters" ->
        dispatch_train_clusters(args)

      # Legacy alias for train_clusters
      "train_gnn" ->
        dispatch_train_clusters(args)

      "predict_links" ->
        dispatch_predict_links(args)

      "cluster_memories" ->
        dispatch_cluster_memories(args)

      unknown ->
        {:error,
         "Unknown neuro_symbolic_inference operation: #{unknown}. Valid: #{inspect(@operations)}"}
    end
  end

  # ===========================================================================
  # Rule Discovery
  # ===========================================================================

  defp dispatch_discover_rules(args) do
    prompt = args["prompt"] || args[:prompt] || ""
    max_rules = args["max_rules"] || args[:max_rules] || 5

    if prompt == "" do
      {:error, "prompt is required for discover_rules"}
    else
      persist_validated = args["persist_validated"] || args[:persist_validated] || false

      RuleGenerator.generate_and_persist_rules(prompt,
        max_rules: max_rules,
        persist_validated: persist_validated
      )
    end
  end

  # ===========================================================================
  # Cross-Modality Linking
  # ===========================================================================

  defp dispatch_link_modalities(%{"entities" => entities} = args) when is_list(entities) do
    pairs =
      entities
      |> Enum.map(fn
        %{"type" => type, "id" => id} -> {String.to_atom(type), id}
        %{type: type, id: id} when is_atom(type) -> {type, id}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    persist = args["persist"] || args[:persist] || false
    CrossModalityLinker.link_all(pairs, persist: persist)
  end

  defp dispatch_link_modalities(_), do: {:error, "entities: required for link_modalities"}

  # ===========================================================================
  # Cluster Training (was train_gnn)
  # ===========================================================================

  # Train k-means clusters on memory embeddings.
  # Args: k (clusters, default 10), sample_size (max memories, default 1000)
  defp dispatch_train_clusters(args) do
    k = args["k"] || args[:k] || 10
    sample_size = args["sample_size"] || args[:sample_size] || 1000

    case GnnPredictor.train(%{k: k, sample_size: sample_size}) do
      {:ok, model} ->
        {:ok,
         %{
           status: "training_complete",
           clusters: model.k,
           sample_size: model.sample_size,
           trained_at: model.trained_at,
           cluster_sizes: model.cluster_sizes
         }}

      {:error, reason} ->
        {:error, "Training failed: #{inspect(reason)}"}
    end
  end

  # ===========================================================================
  # Link Prediction
  # ===========================================================================

  # Predict potential links for given memory IDs based on embedding similarity.
  # Args: memory_ids (list of IDs). Returns top 20 predicted links.
  defp dispatch_predict_links(args) do
    memory_ids = args["memory_ids"] || args[:memory_ids] || []

    if memory_ids == [] do
      {:error, "memory_ids is required for predict_links"}
    else
      # Ensure we have integers
      ids =
        Enum.map(memory_ids, fn
          id when is_integer(id) -> id
          id when is_binary(id) -> String.to_integer(id)
        end)

      predictions = GnnPredictor.predict_links(nil, ids)

      {:ok,
       %{
         predictions: predictions,
         count: length(predictions),
         note: (predictions == [] && "No model trained. Run train_clusters first.") || nil
       }
       |> Map.reject(fn {_, v} -> is_nil(v) end)}
    end
  end

  # ===========================================================================
  # Cluster Analysis
  # ===========================================================================

  # Get cluster assignments for all memories.
  # Returns clusters with member IDs and category breakdown.
  defp dispatch_cluster_memories(args) do
    # Optional: limit to specific memories (not implemented yet)
    _memory_ids = args["memory_ids"] || args[:memory_ids]

    clusters = GnnPredictor.cluster_similar(nil, :memory)

    if clusters == [] do
      {:ok,
       %{
         clusters: [],
         note: "No model trained. Run train_clusters first."
       }}
    else
      {:ok,
       %{
         clusters:
           Enum.map(clusters, fn c ->
             %{
               cluster_id: c.cluster_id,
               size: c.size,
               sample_members: Enum.take(c.member_ids, 10),
               categories: c.category_breakdown,
               avg_similarity: c.avg_similarity
             }
           end),
         total_clusters: length(clusters),
         total_memories: Enum.sum(Enum.map(clusters, & &1.size))
       }}
    end
  end
end
