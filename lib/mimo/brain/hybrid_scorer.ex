defmodule Mimo.Brain.HybridScorer do
  @moduledoc """
  Unified scoring system for hybrid memory retrieval.

  Combines multiple scoring signals into a single relevance score:
  - Vector similarity (semantic relevance)
  - Recency (time-based decay)
  - Access frequency (popularity)
  - Importance (user/system assigned)
  - Graph connectivity (knowledge relationships)

  ## Configuration

      config :mimo_mcp, :hybrid_scoring,
        vector_weight: 0.35,
        recency_weight: 0.25,
        access_weight: 0.15,
        importance_weight: 0.15,
        graph_weight: 0.10

  ## Examples

      # Score a single memory with context
      score = HybridScorer.score(memory, query_embedding, opts)

      # Score and rank multiple memories
      ranked = HybridScorer.rank(memories, query_embedding, opts)
  """

  alias Mimo.Brain.DecayScorer

  @default_weights %{
    vector: 0.35,
    recency: 0.25,
    access: 0.15,
    importance: 0.15,
    graph: 0.10
  }

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Calculate hybrid score for a single memory.

  ## Parameters

    * `memory` - Memory map with fields: embedding, importance, access_count, etc.
    * `query_embedding` - Embedding of the search query (optional)
    * `opts` - Options including custom weights and graph scores

  ## Options

    * `:weights` - Map of weight overrides
    * `:graph_score` - Pre-computed graph connectivity score (0-1)
    * `:vector_similarity` - Pre-computed vector similarity (0-1)

  ## Returns

    Float score between 0.0 and 1.0
  """
  @spec score(map(), list() | nil, keyword()) :: float()
  def score(memory, query_embedding \\ nil, opts \\ []) do
    weights = merge_weights(opts[:weights])

    # Calculate individual scores
    vector_score = calculate_vector_score(memory, query_embedding, opts)
    recency_score = calculate_recency_score(memory)
    access_score = calculate_access_score(memory)
    importance_score = calculate_importance_score(memory)
    graph_score = opts[:graph_score] || 0.0

    # Weighted combination
    score =
      vector_score * weights.vector +
        recency_score * weights.recency +
        access_score * weights.access +
        importance_score * weights.importance +
        graph_score * weights.graph

    # Clamp to 0-1
    min(1.0, max(0.0, score))
  end

  @doc """
  Score and rank multiple memories by hybrid score.

  ## Parameters

    * `memories` - List of memory maps
    * `query_embedding` - Embedding of the search query
    * `opts` - Options passed to score/3

  ## Returns

    List of `{memory, score}` tuples sorted by score descending
  """
  @spec rank([map()], list() | nil, keyword()) :: [{map(), float()}]
  def rank(memories, query_embedding \\ nil, opts \\ []) do
    memories
    |> Enum.map(fn memory ->
      {memory, score(memory, query_embedding, opts)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  Get breakdown of score components for debugging.
  """
  @spec explain(map(), list() | nil, keyword()) :: map()
  def explain(memory, query_embedding \\ nil, opts \\ []) do
    weights = merge_weights(opts[:weights])

    components = %{
      vector: %{
        raw: calculate_vector_score(memory, query_embedding, opts),
        weight: weights.vector
      },
      recency: %{
        raw: calculate_recency_score(memory),
        weight: weights.recency
      },
      access: %{
        raw: calculate_access_score(memory),
        weight: weights.access
      },
      importance: %{
        raw: calculate_importance_score(memory),
        weight: weights.importance
      },
      graph: %{
        raw: opts[:graph_score] || 0.0,
        weight: weights.graph
      }
    }

    weighted =
      Enum.map(components, fn {k, v} ->
        {k, Map.put(v, :weighted, v.raw * v.weight)}
      end)
      |> Map.new()

    total = Enum.reduce(weighted, 0.0, fn {_, v}, acc -> acc + v.weighted end)

    %{
      components: weighted,
      total_score: min(1.0, max(0.0, total)),
      weights: weights
    }
  end

  # ==========================================================================
  # Score Components
  # ==========================================================================

  defp calculate_vector_score(_memory, nil, _opts), do: 0.0

  defp calculate_vector_score(memory, query_embedding, opts) do
    # Use pre-computed similarity if provided
    case opts[:vector_similarity] do
      sim when is_number(sim) ->
        sim

      nil ->
        memory_embedding = Map.get(memory, :embedding)

        if memory_embedding && is_list(memory_embedding) do
          cosine_similarity(memory_embedding, query_embedding)
        else
          0.0
        end
    end
  end

  defp calculate_recency_score(memory) do
    # Use DecayScorer's recency calculation
    DecayScorer.calculate_score(memory)
  end

  defp calculate_access_score(memory) do
    access_count = Map.get(memory, :access_count, 0)
    # Logarithmic scaling, capped at ~10 accesses for max score
    min(1.0, :math.log(1 + access_count) / :math.log(11))
  end

  defp calculate_importance_score(memory) do
    Map.get(memory, :importance, 0.5)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp merge_weights(nil), do: @default_weights

  defp merge_weights(custom) when is_map(custom) do
    Map.merge(@default_weights, custom)
  end

  defp cosine_similarity(a, b) when is_list(a) and is_list(b) do
    if length(a) != length(b) do
      0.0
    else
      dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
      mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

      if mag_a == 0 or mag_b == 0 do
        0.0
      else
        dot / (mag_a * mag_b)
      end
    end
  end

  defp cosine_similarity(_, _), do: 0.0
end
