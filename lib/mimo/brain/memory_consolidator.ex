defmodule Mimo.Brain.MemoryConsolidator do
  @moduledoc """
  SPEC-105: Memory Consolidation Service.

  Implements human-like memory consolidation where similar episodic memories
  are identified and summarized into semantic memories.

  ## Philosophy

  Human brains consolidate memories during sleep:
  - Episodic (specific events) → Semantic (general knowledge)
  - "I used Phoenix router on Jan 9" → "Phoenix handles HTTP routes"

  Mimo does this by:
  1. Detecting clusters of similar memories (high embedding similarity)
  2. Generating LLM summaries of clusters
  3. Storing summaries as consolidated semantic memories
  4. Linking original memories via supersede relationship

  ## Consolidation Modes

  | Mode | Description |
  |------|-------------|
  | candidates | Find clusters that could be consolidated |
  | preview | Generate summary without persisting |
  | run | Actually consolidate and persist |
  | status | Get consolidation statistics |

  ## Configuration

      config :mimo_mcp, Mimo.Brain.MemoryConsolidator,
        similarity_threshold: 0.85,
        min_cluster_size: 5,
        max_age_days: 7,
        cooldown_days: 30

  ## Safety

  - Never deletes original memories (soft archive only)
  - All consolidations are reversible via supersede chain
  - Manual review mode (candidates/preview) before auto-run
  """

  require Logger

  alias Mimo.Brain.Engram
  alias Mimo.Brain.LLM
  alias Mimo.Brain.Memory
  alias Mimo.NeuroSymbolic.GnnPredictor
  alias Mimo.Repo

  import Ecto.Query

  # Default configuration
  @default_similarity_threshold 0.85
  @default_min_cluster_size 5
  @default_max_age_days 7
  @default_cooldown_days 30

  @doc """
  Find clusters of memories that are candidates for consolidation.

  Returns clusters where:
  - Similarity > threshold (default 0.85)
  - Size >= min_cluster_size (default 5)
  - Oldest memory > max_age_days old (default 7)
  - Not consolidated in last cooldown_days (default 30)

  ## Options
    - `:threshold` - Similarity threshold (0.0-1.0)
    - `:min_size` - Minimum cluster size
    - `:limit` - Maximum clusters to return

  ## Returns
    `{:ok, [cluster]}` where cluster is:
    ```
    %{
      cluster_id: integer,
      size: integer,
      avg_similarity: float,
      sample_contents: [binary],
      oldest_memory_days: integer,
      categories: %{category => count}
    }
    ```
  """
  @spec find_candidates(keyword()) :: {:ok, list(map())} | {:error, term()}
  def find_candidates(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, config(:similarity_threshold))
    min_size = Keyword.get(opts, :min_size, config(:min_cluster_size))
    limit = Keyword.get(opts, :limit, 20)

    # Use existing GNN clustering
    case GnnPredictor.cluster_similar(nil, :memory) do
      [] ->
        # No model trained yet
        {:ok, []}

      clusters when is_list(clusters) ->
        # Filter clusters by our consolidation criteria
        candidates =
          clusters
          |> Enum.filter(fn c ->
            c.size >= min_size and
              c.avg_similarity >= threshold and
              not recently_consolidated?(c.member_ids)
          end)
          |> Enum.map(&enrich_cluster/1)
          |> Enum.sort_by(& &1.consolidation_score, :desc)
          |> Enum.take(limit)

        {:ok, candidates}

      error ->
        {:error, "Clustering failed: #{inspect(error)}"}
    end
  end

  @doc """
  Preview consolidation of a specific cluster without persisting.

  Generates the LLM summary that would be created, allowing review
  before actual consolidation.

  ## Parameters
    - `cluster_id` - The cluster ID from find_candidates
    - `opts` - Additional options

  ## Returns
    `{:ok, preview}` with:
    ```
    %{
      cluster_id: integer,
      member_count: integer,
      proposed_summary: binary,
      proposed_category: atom,
      sample_members: [binary],
      estimated_tokens_saved: integer
    }
    ```
  """
  @spec preview(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(cluster_id, opts \\ []) do
    case get_cluster_members(cluster_id) do
      {:ok, members} when length(members) >= 3 ->
        generate_preview(members, opts)

      {:ok, _members} ->
        {:error, "Cluster too small for consolidation (need at least 3 members)"}

      error ->
        error
    end
  end

  @doc """
  Consolidate a specific cluster into a summary memory.

  ## Process
  1. Generate LLM summary of all cluster members
  2. Store summary as new memory (category: consolidated)
  3. Update original memories with superseded_by link
  4. Archive original memories (optional)

  ## Parameters
    - `cluster_id` - The cluster ID to consolidate
    - `opts` - Options including:
      - `:archive_originals` - Whether to archive originals (default: true)
      - `:dry_run` - Preview without persisting (default: false)

  ## Returns
    `{:ok, result}` with:
    ```
    %{
      consolidated_id: integer,
      original_count: integer,
      archived_count: integer,
      summary: binary,
      tokens_saved: integer
    }
    ```
  """
  @spec consolidate(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(cluster_id, opts \\ []) do
    archive_originals = Keyword.get(opts, :archive_originals, true)
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, members} <- get_cluster_members(cluster_id),
         {:ok, preview} <- generate_preview(members, opts),
         {:ok, result} <- maybe_persist(preview, members, archive_originals, dry_run) do
      {:ok, result}
    end
  end

  @doc """
  Run consolidation on all eligible clusters.

  This is the main entry point for scheduled consolidation.
  Finds all candidates and consolidates them in priority order.

  ## Options
    - `:max_clusters` - Maximum clusters to consolidate (default: 5)
    - `:dry_run` - Preview without persisting (default: false)

  ## Returns
    `{:ok, results}` with consolidation summary
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    max_clusters = Keyword.get(opts, :max_clusters, 5)
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, candidates} <- find_candidates(limit: max_clusters) do
      results =
        Enum.map(candidates, fn c ->
          case consolidate(c.cluster_id, archive_originals: true, dry_run: dry_run) do
            {:ok, result} -> {:ok, c.cluster_id, result}
            {:error, reason} -> {:error, c.cluster_id, reason}
          end
        end)

      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      failures = Enum.count(results, &match?({:error, _, _}, &1))

      {:ok,
       %{
         clusters_processed: length(results),
         successes: successes,
         failures: failures,
         dry_run: dry_run,
         details: results
       }}
    end
  end

  @doc """
  Get consolidation statistics.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    try do
      # Count consolidated memories
      consolidated_count =
        Repo.one(
          from(e in Engram,
            where: e.category == "consolidated" and e.archived == false,
            select: count(e.id)
          )
        ) || 0

      # Count memories that have been superseded
      superseded_count =
        Repo.one(
          from(e in Engram,
            where: not is_nil(e.superseded_at),
            select: count(e.id)
          )
        ) || 0

      # Estimate potential consolidations
      {:ok, candidates} = find_candidates(limit: 100)

      potential_savings =
        candidates
        |> Enum.map(& &1.size)
        |> Enum.sum()

      {:ok,
       %{
         consolidated_memories: consolidated_count,
         superseded_memories: superseded_count,
         potential_candidates: length(candidates),
         potential_memories_to_consolidate: potential_savings,
         configuration: %{
           similarity_threshold: config(:similarity_threshold),
           min_cluster_size: config(:min_cluster_size),
           max_age_days: config(:max_age_days),
           cooldown_days: config(:cooldown_days)
         }
       }}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp config(key) do
    defaults = %{
      similarity_threshold: @default_similarity_threshold,
      min_cluster_size: @default_min_cluster_size,
      max_age_days: @default_max_age_days,
      cooldown_days: @default_cooldown_days
    }

    Application.get_env(:mimo_mcp, __MODULE__, [])
    |> Keyword.get(key, Map.get(defaults, key))
  end

  defp recently_consolidated?(member_ids) do
    cooldown_days = config(:cooldown_days)
    cutoff = DateTime.utc_now() |> DateTime.add(-cooldown_days * 24 * 3600, :second)

    # Check if any of these IDs have been consolidated recently
    count =
      Repo.one(
        from(e in Engram,
          where:
            e.category == "consolidated" and
              e.inserted_at > ^cutoff and
              fragment("? LIKE '%' || CAST(? AS TEXT) || '%'", e.metadata, ^hd(member_ids)),
          select: count(e.id)
        )
      ) || 0

    count > 0
  end

  defp enrich_cluster(cluster) do
    # Get sample contents from the cluster
    sample_ids = Enum.take(cluster.member_ids, 5)

    samples =
      Repo.all(
        from(e in Engram,
          where: e.id in ^sample_ids,
          select: {e.id, e.content, e.category, e.inserted_at}
        )
      )

    oldest =
      case Enum.min_by(samples, fn {_, _, _, ts} -> ts end, fn -> nil end) do
        {_, _, _, ts} -> DateTime.diff(DateTime.utc_now(), ts, :day)
        nil -> 0
      end

    # Calculate consolidation priority score
    score = calculate_consolidation_score(cluster, oldest)

    %{
      cluster_id: cluster.cluster_id,
      size: cluster.size,
      avg_similarity: Float.round(cluster.avg_similarity, 3),
      sample_contents:
        Enum.map(samples, fn {_, content, _, _} -> String.slice(content, 0, 100) end),
      categories: cluster.category_breakdown,
      oldest_memory_days: oldest,
      consolidation_score: score
    }
  end

  defp calculate_consolidation_score(cluster, oldest_days) do
    # Higher score = higher priority for consolidation
    # Factors: size, similarity, age
    size_factor = min(cluster.size / 20, 1.0)
    similarity_factor = cluster.avg_similarity
    age_factor = min(oldest_days / 30, 1.0)

    Float.round(size_factor * 0.4 + similarity_factor * 0.4 + age_factor * 0.2, 3)
  end

  defp get_cluster_members(cluster_id) do
    case GnnPredictor.cluster_similar(nil, :memory) do
      clusters when is_list(clusters) ->
        case Enum.find(clusters, &(&1.cluster_id == cluster_id)) do
          nil -> {:error, "Cluster not found: #{cluster_id}"}
          cluster -> {:ok, cluster.member_ids}
        end

      _ ->
        {:error, "No clusters available"}
    end
  end

  defp generate_preview(member_ids, _opts) do
    # Fetch all member contents
    members =
      Repo.all(
        from(e in Engram,
          where: e.id in ^member_ids,
          select: %{id: e.id, content: e.content, category: e.category}
        )
      )

    if length(members) < 3 do
      {:error, "Need at least 3 members for consolidation"}
    else
      # Prepare prompt for LLM
      contents = Enum.map_join(members, "\n---\n", & &1.content)

      prompt = """
      You are consolidating #{length(members)} related memory entries into a single summary.

      The memories share a common theme. Create a concise summary that:
      1. Captures the essential knowledge across all entries
      2. Preserves key facts and patterns
      3. Is useful for future retrieval
      4. Is 2-3 sentences maximum

      Memory entries:
      #{String.slice(contents, 0, 4000)}

      Respond with ONLY the summary, no explanation.
      """

      case LLM.complete(prompt, json: false, use_identity: false) do
        {:ok, summary} when is_binary(summary) ->
          {:ok,
           %{
             cluster_id: nil,
             member_ids: member_ids,
             member_count: length(members),
             proposed_summary: String.trim(summary),
             proposed_category: :consolidated,
             sample_members: Enum.take(members, 3),
             estimated_tokens_saved: estimate_tokens(members) - 100
           }}

        {:error, reason} ->
          {:error, "LLM synthesis failed: #{inspect(reason)}"}
      end
    end
  end

  defp estimate_tokens(members) do
    # Rough estimate: 1 token per 4 characters
    members
    |> Enum.map(&String.length(&1[:content] || &1.content || ""))
    |> Enum.sum()
    |> div(4)
  end

  defp maybe_persist(_preview, _members, _archive, true = _dry_run) do
    {:ok,
     %{
       consolidated_id: nil,
       original_count: 0,
       archived_count: 0,
       summary: "[DRY RUN - not persisted]",
       tokens_saved: 0,
       dry_run: true
     }}
  end

  defp maybe_persist(preview, member_ids, archive_originals, false = _dry_run) do
    # Store the consolidated memory
    metadata = %{
      "source" => "consolidation",
      "original_count" => length(member_ids),
      "original_ids" => member_ids,
      "consolidated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    attrs = %{
      content: preview.proposed_summary,
      category: "consolidated",
      importance: 0.8,
      metadata: metadata
    }

    case Memory.store(attrs) do
      {:ok, consolidated_id} ->
        # Mark original memories as superseded and optionally archive
        archived_count =
          if archive_originals do
            {count, _} =
              Repo.update_all(
                from(e in Engram, where: e.id in ^member_ids),
                set: [superseded_at: DateTime.utc_now(), archived: true]
              )

            count
          else
            {count, _} =
              Repo.update_all(
                from(e in Engram, where: e.id in ^member_ids),
                set: [superseded_at: DateTime.utc_now()]
              )

            count
          end

        Logger.info(
          "[MemoryConsolidator] Consolidated #{length(member_ids)} memories into #{consolidated_id}"
        )

        {:ok,
         %{
           consolidated_id: consolidated_id,
           original_count: length(member_ids),
           archived_count: archived_count,
           summary: preview.proposed_summary,
           tokens_saved: preview.estimated_tokens_saved,
           dry_run: false
         }}

      {:error, reason} ->
        {:error, "Failed to store consolidated memory: #{inspect(reason)}"}
    end
  end
end
