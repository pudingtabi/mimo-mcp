defmodule Mimo.Brain.NoveltyDetector do
  @moduledoc """
  SPEC-034: Classifies incoming memories based on similarity to existing content.

  Uses category-aware thresholds to balance precision and recall.
  Determines if new content should:
  - Be stored as new (no similar memories found)
  - Be treated as redundant (near-duplicate exists)
  - Go through LLM-based decision (ambiguous case)

  ## Classification Outcomes

  - `:redundant` - Near-duplicate exists (sim ≥ redundant_threshold), boost existing
  - `:ambiguous` - Similar memories exist (ambiguous_threshold ≤ sim < redundant_threshold), needs LLM decision
  - `:new` - No similar memories (sim < ambiguous_threshold), store as new

  ## Thresholds by Category

  Different categories have different semantic density, so thresholds vary:

  | Category | Redundant | Ambiguous | Reasoning |
  |----------|-----------|-----------|-----------|
  | fact     | 0.95      | 0.82      | Facts are precise, high bar for redundancy |
  | observation | 0.92   | 0.78      | Observations can be more varied |
  | action   | 0.90      | 0.75      | Actions often share similar patterns |
  | plan     | 0.88      | 0.72      | Plans can be expressed many ways |
  """
  require Logger

  alias Mimo.Brain.{Memory, Engram}
  alias Mimo.Repo

  # Category-specific thresholds (tuned per-category based on semantic density)
  @thresholds %{
    "fact" => %{redundant: 0.95, ambiguous: 0.82},
    "observation" => %{redundant: 0.92, ambiguous: 0.78},
    "action" => %{redundant: 0.90, ambiguous: 0.75},
    "plan" => %{redundant: 0.88, ambiguous: 0.72},
    # Default for other categories (episode, procedure, entity_anchor)
    :default => %{redundant: 0.92, ambiguous: 0.78}
  }

  @type classification :: :redundant | :ambiguous | :new
  @type similar_memory :: %{engram: Engram.t(), similarity: float()}

  @doc """
  Classifies new content and returns similar memories if relevant.

  Returns:
    - `{:redundant, existing_engram}` - Near-duplicate, boost existing
    - `{:ambiguous, [similar_memories]}` - Needs LLM decision
    - `{:new, []}` - Store as new memory

  ## Options

    * `:limit` - Max similar memories to consider (default: 5)
    * `:project_id` - Filter by project (optional)

  ## Examples

      classify("User prefers TypeScript", "observation")
      #=> {:new, []}

      classify("User prefers TypeScript", "observation")  # called again
      #=> {:redundant, %Engram{...}}

      classify("User likes TypeScript for type safety", "observation")
      #=> {:ambiguous, [%{engram: %Engram{...}, similarity: 0.89}]}
  """
  @spec classify(String.t(), String.t(), keyword()) ::
          {:redundant, Engram.t()}
          | {:ambiguous, [similar_memory()]}
          | {:new, []}
  def classify(content, category, opts \\ []) when is_binary(content) and is_binary(category) do
    # Check if TMC is enabled
    unless tmc_enabled?() do
      {:new, []}
    else
      do_classify(content, category, opts)
    end
  end

  defp do_classify(content, category, opts) do
    # Get thresholds for this category
    %{redundant: redundant_thresh, ambiguous: ambiguous_thresh} = thresholds_for(category)

    # Find similar non-superseded memories
    similar = find_similar(content, category, opts)

    case similar do
      [] ->
        {:new, []}

      [%{similarity: sim, engram: engram} | _rest] when sim >= redundant_thresh ->
        Logger.debug("NoveltyDetector: redundant memory found (sim=#{Float.round(sim, 3)})")
        {:redundant, engram}

      matches ->
        # Filter to only those above ambiguous threshold
        ambiguous = Enum.filter(matches, fn %{similarity: s} -> s >= ambiguous_thresh end)

        if Enum.empty?(ambiguous) do
          {:new, []}
        else
          Logger.debug("NoveltyDetector: #{length(ambiguous)} ambiguous matches found")
          {:ambiguous, ambiguous}
        end
    end
  end

  @doc """
  Find memories similar to content, filtering already-superseded ones.

  Only returns active (non-superseded) memories for comparison.

  ## Options

    * `:limit` - Maximum results (default: 5)
    * `:min_similarity` - Minimum similarity to consider (default: 0.70)
    * `:project_id` - Filter by project (optional)

  ## Examples

      find_similar("deployment failed", "action")
      #=> [%{engram: %Engram{...}, similarity: 0.85}]
  """
  @spec find_similar(String.t(), String.t(), keyword()) :: [similar_memory()]
  def find_similar(content, category, opts \\ []) when is_binary(content) do
    limit = Keyword.get(opts, :limit, 5)
    min_similarity = Keyword.get(opts, :min_similarity, 0.70)
    project_id = Keyword.get(opts, :project_id)

    # Use existing search with category filter
    search_opts = [
      # Get more candidates since we'll filter
      limit: limit * 2,
      min_similarity: min_similarity,
      strategy: :auto
    ]

    results = Memory.search_memories(content, search_opts)

    # Filter to matching category, non-superseded, and optionally project
    results
    |> Enum.filter(fn result ->
      # Category match
      # Not superseded (active)
      # Project match if specified
      result[:category] == category and
        is_nil(result[:superseded_at]) and
        (is_nil(project_id) or result[:project_id] == project_id)
    end)
    |> Enum.take(limit)
    |> Enum.map(fn result ->
      # Fetch full engram for the result
      case Repo.get(Engram, result[:id]) do
        nil -> nil
        engram -> %{engram: engram, similarity: result[:similarity] || 0.0}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get similarity thresholds for a category.

  ## Examples

      thresholds_for("fact")
      #=> %{redundant: 0.95, ambiguous: 0.82}

      thresholds_for("unknown_category")
      #=> %{redundant: 0.92, ambiguous: 0.78}  # default
  """
  @spec thresholds_for(String.t() | atom()) :: %{redundant: float(), ambiguous: float()}
  def thresholds_for(category) when is_binary(category) do
    Map.get(@thresholds, category, @thresholds[:default])
  end

  def thresholds_for(category) when is_atom(category) do
    thresholds_for(to_string(category))
  end

  @doc """
  Returns all configured thresholds.
  Useful for debugging and monitoring.
  """
  @spec all_thresholds() :: map()
  def all_thresholds, do: @thresholds

  @doc """
  Check if Temporal Memory Chains feature is enabled.
  """
  @spec tmc_enabled?() :: boolean()
  def tmc_enabled? do
    case Application.get_env(:mimo_mcp, :feature_flags, [])[:temporal_memory_chains] do
      {:system, env_var, default} ->
        case System.get_env(env_var) do
          "true" -> true
          "1" -> true
          nil -> default
          _ -> false
        end

      true ->
        true

      false ->
        false

      nil ->
        false
    end
  end

  @doc """
  Classify content with detailed explanation (for debugging).

  Returns a map with classification, reasoning, and matched memories.

  ## Examples

      explain_classification("User prefers dark mode", "observation")
      #=> %{
        classification: :ambiguous,
        category: "observation",
        thresholds: %{redundant: 0.92, ambiguous: 0.78},
        similar_count: 2,
        top_similarity: 0.85,
        similar_memories: [...]
      }
  """
  @spec explain_classification(String.t(), String.t(), keyword()) :: map()
  def explain_classification(content, category, opts \\ []) do
    thresholds = thresholds_for(category)
    similar = find_similar(content, category, opts)

    {classification, target} =
      case classify(content, category, opts) do
        {:redundant, engram} -> {:redundant, engram}
        {:ambiguous, matches} -> {:ambiguous, matches}
        {:new, []} -> {:new, nil}
      end

    %{
      classification: classification,
      category: category,
      thresholds: thresholds,
      tmc_enabled: tmc_enabled?(),
      similar_count: length(similar),
      top_similarity:
        case similar do
          [%{similarity: s} | _] -> s
          [] -> 0.0
        end,
      similar_memories:
        Enum.map(similar, fn %{engram: e, similarity: s} ->
          %{
            id: e.id,
            content_preview: String.slice(e.content || "", 0, 100),
            similarity: Float.round(s, 4),
            superseded: not is_nil(e.superseded_at)
          }
        end),
      target:
        case target do
          %Engram{} = e -> %{id: e.id, content_preview: String.slice(e.content || "", 0, 100)}
          list when is_list(list) -> length(list)
          nil -> nil
        end
    }
  end
end
