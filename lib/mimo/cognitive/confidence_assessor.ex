defmodule Mimo.Cognitive.ConfidenceAssessor do
  @moduledoc """
  Assesses confidence in Mimo's knowledge about a topic.

  This is the core assessment engine for SPEC-024 Phase 1 (Epistemic Uncertainty).
  It combines evidence from multiple sources to determine how confident Mimo
  should be when answering questions.

  ## Assessment Factors

  1. **Memory Evidence** - Number and relevance of related memories
  2. **Code Knowledge** - Symbol index matches for code-related queries
  3. **Library Knowledge** - Cached documentation for mentioned packages
  4. **Graph Context** - Related nodes in the Synapse knowledge graph
  5. **Recency** - How recent the information is
  6. **Source Diversity** - Multiple independent sources increase confidence

  ## Example

      # Assess confidence for a query
      uncertainty = ConfidenceAssessor.assess("How does Phoenix authentication work?")

      # Check if we have sufficient knowledge
      if uncertainty.confidence in [:high, :medium] do
        # Proceed with answering
      else
        # Consider researching or asking for clarification
      end
  """

  require Logger

  alias CacheManager
  alias Mimo.Brain.Memory
  alias Mimo.Code.SymbolIndex
  alias Mimo.Cognitive.Uncertainty
  alias Mimo.Synapse.QueryEngine
  alias Mimo.TaskHelper

  @type assessment_opts :: [
          include_memories: boolean(),
          include_code: boolean(),
          include_graph: boolean(),
          include_library: boolean(),
          memory_limit: pos_integer(),
          code_limit: pos_integer(),
          graph_limit: pos_integer()
        ]

  # Weight factors for different evidence sources
  @weights %{
    memory_count: 0.15,
    memory_recency: 0.10,
    memory_relevance: 0.15,
    code_presence: 0.20,
    graph_relevance: 0.20,
    source_diversity: 0.10,
    library_knowledge: 0.10
  }

  # Recency thresholds (in days)
  @recency_thresholds %{
    very_recent: 1,
    recent: 7,
    moderate: 30,
    stale: 90
  }

  @doc """
  Assess confidence for a query/topic.

  Gathers evidence from multiple sources and calculates a confidence score.

  ## Options

  - `:include_memories` - Search episodic memory (default: true)
  - `:include_code` - Search code symbol index (default: true)
  - `:include_graph` - Search Synapse knowledge graph (default: true)
  - `:include_library` - Check library cache (default: true)
  - `:memory_limit` - Max memories to retrieve (default: 10)
  - `:code_limit` - Max code symbols to retrieve (default: 10)
  - `:graph_limit` - Max graph nodes to retrieve (default: 10)

  ## Returns

  An `Uncertainty` struct with confidence assessment.
  """
  @spec assess(String.t(), assessment_opts()) :: Uncertainty.t()
  def assess(query, opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)

    # Gather evidence from multiple sources in parallel
    evidence_tasks = build_evidence_tasks(query, opts)

    evidence =
      evidence_tasks
      |> TaskHelper.async_stream_with_callers(fn {key, fun} -> {key, fun.()} end,
        timeout: 5000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, result}}, acc -> Map.put(acc, key, result)
        {:exit, _reason}, acc -> acc
      end)

    # Calculate scores
    scores = calculate_scores(evidence, query)

    # Detect staleness
    staleness = calculate_staleness(evidence)

    # Identify potential gaps
    gap_indicators = identify_gaps(evidence, query)

    # Build sources list
    sources = build_sources(evidence)

    # Calculate final weighted score
    final_score = calculate_weighted_score(scores)

    Uncertainty.from_assessment(
      query,
      final_score,
      sources,
      staleness: staleness,
      gap_indicators: gap_indicators
    )
  end

  @doc """
  Quick confidence check without full assessment.
  Returns just the confidence level.
  """
  @spec quick_assess(String.t()) :: Uncertainty.confidence_level()
  def quick_assess(query) do
    # Only check memories for speed
    memories = safe_search_memories(query, 5)

    cond do
      length(memories) >= 3 -> :high
      memories != [] -> :medium
      true -> :unknown
    end
  end

  @doc """
  Assess confidence for a code-related query.
  Prioritizes code symbol index.
  """
  @spec assess_code(String.t(), keyword()) :: Uncertainty.t()
  def assess_code(query, opts \\ []) do
    opts =
      Keyword.merge(opts,
        include_code: true,
        include_library: true,
        code_limit: 20
      )

    assess(query, opts)
  end

  @doc """
  Assess confidence for a conceptual query.
  Prioritizes memory and graph sources.
  """
  @spec assess_concept(String.t(), keyword()) :: Uncertainty.t()
  def assess_concept(query, opts \\ []) do
    opts =
      Keyword.merge(opts,
        include_memories: true,
        include_graph: true,
        memory_limit: 20
      )

    assess(query, opts)
  end

  # Private functions

  defp default_opts do
    [
      include_memories: true,
      include_code: true,
      include_graph: true,
      include_library: true,
      memory_limit: 10,
      code_limit: 10,
      graph_limit: 10
    ]
  end

  defp build_evidence_tasks(query, opts) do
    tasks = []

    tasks =
      if opts[:include_memories] do
        [{:memories, fn -> safe_search_memories(query, opts[:memory_limit]) end} | tasks]
      else
        tasks
      end

    tasks =
      if opts[:include_code] do
        [{:code, fn -> safe_search_code(query, opts[:code_limit]) end} | tasks]
      else
        tasks
      end

    tasks =
      if opts[:include_graph] do
        [{:graph, fn -> safe_search_graph(query, opts[:graph_limit]) end} | tasks]
      else
        tasks
      end

    tasks =
      if opts[:include_library] do
        [{:library, fn -> check_library_knowledge(query) end} | tasks]
      else
        tasks
      end

    tasks
  end

  defp safe_search_memories(query, limit) do
    try do
      Memory.search_memories(query, limit: limit, min_similarity: 0.3)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp safe_search_code(query, limit) do
    try do
      # Extract potential symbol names from query
      words =
        query
        |> String.downcase()
        |> String.split(~r/\s+/)
        |> Enum.filter(&(String.length(&1) > 2))

      # Search for each word
      words
      |> Enum.flat_map(fn word ->
        SymbolIndex.search(word, limit: div(limit, max(length(words), 1)))
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp safe_search_graph(query, limit) do
    try do
      case QueryEngine.query(query, max_nodes: limit) do
        {:ok, result} -> result.nodes
        _ -> []
      end
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp check_library_knowledge(query) do
    # Extract potential library names from query
    libraries = extract_library_names(query)

    libraries
    |> Enum.map(fn {name, ecosystem} ->
      cached = Mimo.Library.CacheManager.cached?(name, ecosystem)
      %{name: name, ecosystem: ecosystem, cached: cached}
    end)
  end

  defp extract_library_names(query) do
    # Common patterns for library mentions
    patterns = [
      # Elixir/Hex packages
      ~r/\b(phoenix|ecto|plug|jason|req|oban|broadway|absinthe|guardian)\b/i,
      # Python packages
      ~r/\b(requests|numpy|pandas|flask|django|fastapi|pytest)\b/i,
      # NPM packages
      ~r/\b(express|react|next|lodash|axios|typescript|jest)\b/i
    ]

    ecosystems = [:hex, :pypi, :npm]

    patterns
    |> Enum.zip(ecosystems)
    |> Enum.flat_map(fn {pattern, ecosystem} ->
      Regex.scan(pattern, query)
      |> Enum.map(fn [match | _] -> {String.downcase(match), ecosystem} end)
    end)
    |> Enum.uniq()
  end

  defp calculate_scores(evidence, query) do
    %{
      memory_count: score_memory_count(evidence[:memories] || []),
      memory_recency: score_memory_recency(evidence[:memories] || []),
      memory_relevance: score_memory_relevance(evidence[:memories] || [], query),
      code_presence: score_code_presence(evidence[:code] || []),
      graph_relevance: score_graph_relevance(evidence[:graph] || []),
      source_diversity: score_source_diversity(evidence),
      library_knowledge: score_library_knowledge(evidence[:library] || [])
    }
  end

  defp score_memory_count(memories) do
    count = length(memories)

    cond do
      count >= 5 -> 1.0
      count >= 3 -> 0.8
      count >= 1 -> 0.5
      true -> 0.0
    end
  end

  defp score_memory_recency(memories) do
    if memories == [] do
      0.0
    else
      now = DateTime.utc_now()

      recent_count =
        memories
        |> Enum.count(fn m ->
          case m[:inserted_at] do
            nil ->
              false

            inserted_at when is_struct(inserted_at, DateTime) ->
              DateTime.diff(now, inserted_at, :day) <= @recency_thresholds.recent

            inserted_at when is_struct(inserted_at, NaiveDateTime) ->
              NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :day) <=
                @recency_thresholds.recent

            _ ->
              false
          end
        end)

      recent_count / max(length(memories), 1)
    end
  end

  defp score_memory_relevance(memories, _query) do
    if memories == [] do
      0.0
    else
      avg_similarity =
        memories
        |> Enum.map(fn m -> m[:similarity] || 0.0 end)
        |> Enum.sum()
        |> Kernel./(max(length(memories), 1))

      # Scale from 0.3-1.0 range to 0-1
      min(1.0, max(0.0, (avg_similarity - 0.3) / 0.7))
    end
  end

  defp score_code_presence(symbols) do
    count = length(symbols)

    cond do
      count >= 5 -> 1.0
      count >= 3 -> 0.8
      count >= 1 -> 0.6
      true -> 0.0
    end
  end

  defp score_graph_relevance(nodes) do
    count = length(nodes)

    cond do
      count >= 10 -> 1.0
      count >= 5 -> 0.8
      count >= 2 -> 0.6
      count >= 1 -> 0.4
      true -> 0.0
    end
  end

  defp score_source_diversity(evidence) do
    sources_with_data =
      [:memories, :code, :graph, :library]
      |> Enum.count(fn key ->
        case evidence[key] do
          nil -> false
          [] -> false
          list when is_list(list) -> list != []
          _ -> false
        end
      end)

    sources_with_data / 4.0
  end

  defp score_library_knowledge(library_info) do
    if library_info == [] do
      0.0
    else
      cached_count = Enum.count(library_info, & &1.cached)
      cached_count / max(length(library_info), 1)
    end
  end

  defp calculate_weighted_score(scores) do
    @weights
    |> Enum.map(fn {key, weight} ->
      score = Map.get(scores, key, 0.0)
      score * weight
    end)
    |> Enum.sum()
  end

  defp calculate_staleness(evidence) do
    memories = evidence[:memories] || []

    if memories == [] do
      1.0
    else
      now = DateTime.utc_now()

      avg_age_days =
        memories
        |> Enum.map(fn m ->
          case m[:inserted_at] do
            nil ->
              @recency_thresholds.stale

            inserted_at when is_struct(inserted_at, DateTime) ->
              DateTime.diff(now, inserted_at, :day)

            inserted_at when is_struct(inserted_at, NaiveDateTime) ->
              NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :day)

            _ ->
              @recency_thresholds.stale
          end
        end)
        |> Enum.sum()
        |> Kernel./(max(length(memories), 1))

      cond do
        avg_age_days <= @recency_thresholds.very_recent -> 0.0
        avg_age_days <= @recency_thresholds.recent -> 0.1
        avg_age_days <= @recency_thresholds.moderate -> 0.3
        avg_age_days <= @recency_thresholds.stale -> 0.5
        true -> 0.8
      end
    end
  end

  defp identify_gaps(evidence, query) do
    []
    |> add_library_gaps(evidence[:library] || [])
    |> add_code_gaps(evidence[:code] || [], query)
    |> add_memory_gaps(evidence[:memories] || [])
  end

  defp add_library_gaps(gaps, libraries) do
    library_gaps =
      libraries
      |> Enum.reject(& &1.cached)
      |> Enum.map(fn lib -> "Missing documentation for #{lib.ecosystem}:#{lib.name}" end)

    gaps ++ library_gaps
  end

  defp add_code_gaps(gaps, [], query) do
    if String.match?(query, ~r/function|module|class|method|def|implement/i) do
      ["No code symbols found for code-related query" | gaps]
    else
      gaps
    end
  end

  defp add_code_gaps(gaps, _code, _query), do: gaps

  defp add_memory_gaps(gaps, []), do: gaps

  defp add_memory_gaps(gaps, memories) do
    avg_relevance =
      memories
      |> Enum.map(fn m -> m[:similarity] || 0.0 end)
      |> Enum.sum()
      |> Kernel./(length(memories))

    if avg_relevance < 0.4 do
      ["Low relevance in available memories (avg: #{Float.round(avg_relevance, 2)})" | gaps]
    else
      gaps
    end
  end

  defp build_sources(evidence) do
    memory_sources =
      (evidence[:memories] || [])
      |> Enum.map(fn m ->
        %{
          type: :memory,
          id: to_string(m[:id]),
          name: String.slice(m[:content] || "", 0..50),
          relevance: m[:similarity] || 0.0
        }
      end)

    code_sources =
      (evidence[:code] || [])
      |> Enum.map(fn s ->
        %{
          type: :code,
          id: s.id,
          name: s.qualified_name || s.name,
          relevance: 0.7
        }
      end)

    graph_sources =
      (evidence[:graph] || [])
      |> Enum.map(fn n ->
        %{
          type: :graph,
          id: n.id,
          name: n.name,
          relevance: 0.6
        }
      end)

    library_sources =
      (evidence[:library] || [])
      |> Enum.filter(& &1.cached)
      |> Enum.map(fn lib ->
        %{
          type: :library,
          id: nil,
          name: "#{lib.ecosystem}:#{lib.name}",
          relevance: 0.8
        }
      end)

    memory_sources ++ code_sources ++ graph_sources ++ library_sources
  end
end
