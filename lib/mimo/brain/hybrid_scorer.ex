defmodule Mimo.Brain.HybridScorer do
  @moduledoc """
  Unified scoring system for hybrid memory retrieval.

  Combines multiple scoring signals into a single relevance score:
  - Vector similarity (semantic relevance)
  - Recency (time-based decay)
  - Access frequency (popularity)
  - Importance (user/system assigned)
  - Graph connectivity (knowledge relationships)
  - Cross-modality connectivity (SPEC-051)

  ## Configuration

      config :mimo_mcp, :hybrid_scoring,
        vector_weight: 0.35,
        recency_weight: 0.25,
        access_weight: 0.15,
        importance_weight: 0.15,
        graph_weight: 0.10

  ## Tiered Context (SPEC-051)

  The scorer supports tiered context delivery for optimizing token usage:

  - Tier 1 (Essential): URS >= 0.85 - Critical for immediate execution
  - Tier 2 (Supporting): URS >= 0.65 - Important supporting context  
  - Tier 3 (Background): URS < 0.65 - Available on demand

  ## Examples

      # Score a single memory with context
      score = HybridScorer.score(memory, query_embedding, opts)

      # Score and rank multiple memories
      ranked = HybridScorer.rank(memories, query_embedding, opts)

      # Classify into tiers (SPEC-051)
      tier = HybridScorer.classify_tier(item, query_embedding, opts)
      # => :tier1, :tier2, or :tier3
  """

  alias Mimo.Brain.DecayScorer
  alias Mimo.NeuroSymbolic.CrossModalityLinker

  @default_weights %{
    vector: 0.35,
    recency: 0.25,
    access: 0.15,
    importance: 0.15,
    graph: 0.10
  }

  # SPEC-051: Unified Relevance Score weights
  # URS = (Semantic * 0.35) + (Temporal * 0.25) + (Importance * 0.20) + (CrossModal * 0.20)
  @urs_weights %{
    semantic: 0.35,
    temporal: 0.25,
    importance: 0.20,
    cross_modality: 0.20
  }

  # SPEC-051: Tier classification thresholds
  @tier_thresholds %{
    tier1: 0.85,
    tier2: 0.65
  }

  # SPEC-051: Model-aware threshold adjustments
  # Small models get slightly stricter thresholds to maximize token efficiency
  @model_threshold_adjustments %{
    small: %{tier1: 0.02, tier2: 0.02},
    medium: %{tier1: 0.0, tier2: 0.0},
    large: %{tier1: -0.02, tier2: -0.02}
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
  # SPEC-051: Tiered Context Classification
  # ==========================================================================

  @doc """
  Classify an item into a tier based on Unified Relevance Score.

  SPEC-051: Uses URS combining semantic, temporal, importance, and cross-modality signals.

  ## Parameters

    * `item` - Context item (memory, code symbol, etc.)
    * `query_embedding` - Query embedding for semantic scoring (optional)
    * `opts` - Options:
      * `:model_type` - :small, :medium, :large (affects thresholds)
      * `:vector_similarity` - Pre-computed similarity score
      * `:cross_modality_connections` - Number of cross-source connections (0, 1, 2+)

  ## Returns

    Atom: :tier1, :tier2, or :tier3
  """
  @spec classify_tier(map(), list() | nil, keyword()) :: :tier1 | :tier2 | :tier3
  def classify_tier(item, query_embedding \\ nil, opts \\ []) do
    urs = calculate_unified_score(item, query_embedding, opts)
    model_type = opts[:model_type] || :medium
    thresholds = adjusted_thresholds(model_type)

    cond do
      urs >= thresholds.tier1 -> :tier1
      urs >= thresholds.tier2 -> :tier2
      true -> :tier3
    end
  end

  @doc """
  Calculate Unified Relevance Score (URS) for an item.

  SPEC-051: URS = (Semantic * 0.35) + (Temporal * 0.25) + (Importance * 0.20) + (CrossModal * 0.20)

  ## Parameters

    * `item` - Context item with relevant fields
    * `query_embedding` - Query embedding for semantic scoring
    * `opts` - Options including pre-computed scores

  ## Returns

    Float score between 0.0 and 1.0
  """
  @spec calculate_unified_score(map(), list() | nil, keyword()) :: float()
  def calculate_unified_score(item, query_embedding \\ nil, opts \\ []) do
    # Component scores
    semantic = calculate_vector_score(item, query_embedding, opts)
    temporal = calculate_temporal_score(item)
    importance = calculate_importance_score(item)
    cross_modal = calculate_cross_modality_score(item, opts)

    # Weighted combination using URS weights
    urs =
      semantic * @urs_weights.semantic +
        temporal * @urs_weights.temporal +
        importance * @urs_weights.importance +
        cross_modal * @urs_weights.cross_modality

    min(1.0, max(0.0, urs))
  end

  @doc """
  Calculate cross-modality connectivity score.

  SPEC-051: Items connected across multiple sources (memory ↔ code ↔ knowledge) score higher.

  ## Scoring:
    - Isolated item (no connections): 0.0
    - Connected to 1 other source: +0.5
    - Connected to 2+ other sources: +1.0

  ## Parameters

    * `item` - Context item, may have :cross_modality_connections field
    * `opts` - Options including :cross_modality_connections override, :use_linker

  ## Returns

    Float score between 0.0 and 1.0
  """
  @spec calculate_cross_modality_score(map(), keyword()) :: float()
  def calculate_cross_modality_score(item, opts \\ []) do
    connections =
      opts[:cross_modality_connections] ||
        Map.get(item, :cross_modality_connections) ||
        Map.get(item, :cross_modality) ||
        lookup_or_infer_connections(item, opts)

    connection_count =
      cond do
        is_list(connections) -> length(connections)
        is_integer(connections) -> connections
        true -> 0
      end

    case connection_count do
      0 -> 0.0
      1 -> 0.5
      _ -> 1.0
    end
  end

  @doc """
  Classify multiple items into tiers and return grouped results.

  ## Parameters

    * `items` - List of context items
    * `query_embedding` - Query embedding for scoring
    * `opts` - Options passed to classify_tier/3

  ## Returns

    Map with tier keys: %{tier1: [...], tier2: [...], tier3: [...]}
  """
  @spec classify_items([map()], list() | nil, keyword()) :: %{
          tier1: [map()],
          tier2: [map()],
          tier3: [map()]
        }
  def classify_items(items, query_embedding \\ nil, opts \\ []) do
    items
    |> Enum.map(fn item ->
      tier = classify_tier(item, query_embedding, opts)
      urs = calculate_unified_score(item, query_embedding, opts)
      {tier, Map.put(item, :urs, urs)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.merge(%{tier1: [], tier2: [], tier3: []}, fn _k, v1, _v2 -> v1 end)
    |> Map.new(fn {tier, tier_items} ->
      # Sort each tier by URS descending
      {tier, Enum.sort_by(tier_items, & &1[:urs], :desc)}
    end)
  end

  @doc """
  Get explanation of tier classification including URS breakdown.
  """
  @spec explain_tier(map(), list() | nil, keyword()) :: map()
  def explain_tier(item, query_embedding \\ nil, opts \\ []) do
    model_type = opts[:model_type] || :medium
    thresholds = adjusted_thresholds(model_type)

    semantic = calculate_vector_score(item, query_embedding, opts)
    temporal = calculate_temporal_score(item)
    importance = calculate_importance_score(item)
    cross_modal = calculate_cross_modality_score(item, opts)

    urs = calculate_unified_score(item, query_embedding, opts)
    tier = classify_tier(item, query_embedding, opts)

    %{
      tier: tier,
      unified_relevance_score: urs,
      thresholds: thresholds,
      model_type: model_type,
      components: %{
        semantic: %{
          raw: semantic,
          weight: @urs_weights.semantic,
          weighted: semantic * @urs_weights.semantic
        },
        temporal: %{
          raw: temporal,
          weight: @urs_weights.temporal,
          weighted: temporal * @urs_weights.temporal
        },
        importance: %{
          raw: importance,
          weight: @urs_weights.importance,
          weighted: importance * @urs_weights.importance
        },
        cross_modality: %{
          raw: cross_modal,
          weight: @urs_weights.cross_modality,
          weighted: cross_modal * @urs_weights.cross_modality
        }
      }
    }
  end

  # ==========================================================================
  # Score Components
  # ==========================================================================

  defp calculate_vector_score(memory, query_embedding, opts) when is_list(opts) do
    # Use pre-computed similarity if provided (takes precedence over embedding calculation)
    case opts[:vector_similarity] do
      sim when is_number(sim) ->
        sim

      nil ->
        calculate_vector_score_from_embedding(memory, query_embedding, opts)
    end
  end

  defp calculate_vector_score(memory, query_embedding, _opts) do
    calculate_vector_score_from_embedding(memory, query_embedding, [])
  end

  defp calculate_vector_score_from_embedding(_memory, nil, _opts), do: 0.0

  defp calculate_vector_score_from_embedding(memory, query_embedding, _opts) do
    memory_embedding = Map.get(memory, :embedding)

    if memory_embedding && is_list(memory_embedding) do
      cosine_similarity(memory_embedding, query_embedding)
    else
      0.0
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

  # SPEC-051: Temporal score combining recency and access frequency
  defp calculate_temporal_score(item) do
    recency = calculate_recency_score(item)
    access = calculate_access_score(item)
    # Combined temporal score (recency more important than access frequency)
    recency * 0.7 + access * 0.3
  end

  # SPEC-051: Infer cross-modality connections from item metadata
  defp infer_connections(item) do
    connections = []

    # Check for code references
    connections =
      if Map.has_key?(item, :code_refs) or Map.has_key?(item, :symbol) or
           Map.has_key?(item, :file_path) do
        [:code | connections]
      else
        connections
      end

    # Check for memory references
    connections =
      if Map.has_key?(item, :memory_ids) or Map.has_key?(item, :memory_refs) do
        [:memory | connections]
      else
        connections
      end

    # Check for knowledge graph references
    connections =
      if Map.has_key?(item, :graph_nodes) or Map.has_key?(item, :knowledge_refs) or
           Map.has_key?(item, :relationships) do
        [:knowledge | connections]
      else
        connections
      end

    # Check for library references
    connections =
      if Map.has_key?(item, :package) or Map.has_key?(item, :library_refs) do
        [:library | connections]
      else
        connections
      end

    connections
  end

  # SPEC-051 Phase 2: Lookup or infer cross-modality connections
  # Uses CrossModalityLinker when :use_linker option is true or item has an ID
  defp lookup_or_infer_connections(item, opts) do
    use_linker = Keyword.get(opts, :use_linker, false)

    if use_linker and item[:id] do
      # Use the CrossModalityLinker to find actual connections
      CrossModalityLinker.find_cross_connections(item, limit: 10, min_confidence: 0.5)
    else
      # Fall back to metadata inference (faster, no DB lookup)
      infer_connections(item)
    end
  end

  # SPEC-051: Get thresholds adjusted for model type
  defp adjusted_thresholds(model_type) do
    adjustments = Map.get(@model_threshold_adjustments, model_type, %{tier1: 0.0, tier2: 0.0})

    %{
      tier1: @tier_thresholds.tier1 + adjustments.tier1,
      tier2: @tier_thresholds.tier2 + adjustments.tier2
    }
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
