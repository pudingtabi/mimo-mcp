defmodule Mimo.Brain.Emergence.Amplifier do
  @moduledoc """
  SPEC-044: Conditions that increase emergence likelihood.

  Emergence requires specific conditions to flourish:

  1. **Diversity**: Different types of components interacting
  2. **Connectivity**: Rich connections between components
  3. **Feedback Loops**: Outputs influencing inputs
  4. **Persistence**: State maintained across time
  5. **Pressure**: Challenges that drive adaptation

  This module provides functions to amplify these conditions,
  making emergence more likely to occur naturally.

  ## Amplification Strategies

  - `increase_connectivity/0` - Auto-link related concepts
  - `encourage_diversity/0` - Use varied reasoning strategies
  - `strengthen_feedback_loops/0` - Track outcomes, reinforce patterns
  - `add_creative_pressure/0` - Generate questions, challenge assumptions
  """

  require Logger

  alias Mimo.Brain.{Memory, Interaction}
  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.SemanticStore.Ingestor
  alias Mimo.Repo
  import Ecto.Query

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Runs all amplification strategies.
  Returns summary of actions taken.
  """
  @spec amplify_conditions() :: {:ok, map()} | {:error, term()}
  def amplify_conditions do
    Logger.info("[Emergence.Amplifier] Running amplification strategies")

    results = %{
      connectivity: increase_connectivity(),
      diversity: encourage_diversity(),
      feedback_loops: strengthen_feedback_loops(),
      creative_pressure: add_creative_pressure()
    }

    {:ok, results}
  end

  @doc """
  Increases connectivity between system components.
  Automatically links related concepts in knowledge graph.
  """
  @spec increase_connectivity() :: map()
  def increase_connectivity do
    Logger.debug("[Amplifier] Increasing connectivity")

    results = %{
      concepts_linked: auto_link_concepts(),
      memories_linked: link_memories_to_graph(),
      temporal_chains: build_temporal_chains()
    }

    results
  end

  @doc """
  Encourages diversity in reasoning and tool usage.
  """
  @spec encourage_diversity() :: map()
  def encourage_diversity do
    Logger.debug("[Amplifier] Encouraging diversity")

    results = %{
      strategy_rotation: analyze_strategy_diversity(),
      memory_cross_store: analyze_cross_store_usage(),
      tool_exploration: analyze_tool_diversity()
    }

    results
  end

  @doc """
  Strengthens feedback loops in the system.
  """
  @spec strengthen_feedback_loops() :: map()
  def strengthen_feedback_loops do
    Logger.debug("[Amplifier] Strengthening feedback loops")

    results = %{
      outcomes_tracked: track_outcomes(),
      patterns_reinforced: reinforce_successful_patterns(),
      failures_learned: store_failure_patterns()
    }

    results
  end

  @doc """
  Adds creative pressure to drive adaptation.
  """
  @spec add_creative_pressure() :: map()
  def add_creative_pressure do
    Logger.debug("[Amplifier] Adding creative pressure")

    results = %{
      questions_generated: generate_exploratory_questions(),
      assumptions_challenged: identify_assumptions_to_challenge(),
      distant_connections: explore_distant_relations()
    }

    results
  end

  # ─────────────────────────────────────────────────────────────────
  # Connectivity Strategies
  # ─────────────────────────────────────────────────────────────────

  defp auto_link_concepts do
    # Find memories that mention similar concepts and link them
    recent_memories = get_recent_memories(days: 7)

    # Extract key concepts from memories
    concept_pairs =
      recent_memories
      |> extract_concepts()
      |> find_linkable_pairs()

    # Create links in knowledge graph
    linked =
      concept_pairs
      |> Enum.map(fn {concept1, concept2, relation} ->
        case create_knowledge_link(concept1, concept2, relation) do
          {:ok, _} -> true
          _ -> false
        end
      end)
      |> Enum.count(& &1)

    %{pairs_found: length(concept_pairs), links_created: linked}
  end

  defp link_memories_to_graph do
    # Find memories that reference code symbols and link them
    recent_memories = get_recent_memories(days: 7, category: "fact")

    linked =
      recent_memories
      |> Enum.map(fn memory ->
        # Extract potential code references
        code_refs = extract_code_references(memory[:content] || "")

        # Link each reference to the memory in the graph
        Enum.map(code_refs, fn ref ->
          link_memory_to_code(memory[:id], ref)
        end)
      end)
      |> List.flatten()
      |> Enum.count(&match?({:ok, _}, &1))

    %{memories_processed: length(recent_memories), links_created: linked}
  end

  defp build_temporal_chains do
    # Create temporal links between memories that are related and close in time
    # This helps surface patterns in how the system evolves

    memories_with_time = get_memories_with_timestamps(days: 7)

    # Group by similarity and time proximity
    chains =
      memories_with_time
      |> group_by_time_window(hours: 2)
      |> Enum.map(&create_temporal_chain/1)
      |> Enum.reject(&is_nil/1)

    %{chains_created: length(chains)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Diversity Strategies
  # ─────────────────────────────────────────────────────────────────

  defp analyze_strategy_diversity do
    # Analyze if reasoning strategies are being varied
    # A healthy system uses different strategies for different problems

    # Get recent reasoning sessions (would need access to Reason module data)
    # For now, return analysis placeholder
    %{
      strategies_used: ["cot", "tot", "react"],
      diversity_score: 0.7,
      recommendation: "Good diversity in reasoning strategies"
    }
  end

  defp analyze_cross_store_usage do
    # Check if both episodic and semantic stores are being queried
    # Cross-store retrieval leads to richer context

    recent_queries = get_recent_memory_queries(days: 7)

    stores_used =
      recent_queries
      |> Enum.map(& &1[:store])
      |> Enum.frequencies()

    %{
      stores_used: stores_used,
      cross_store_ratio: calculate_cross_store_ratio(stores_used)
    }
  end

  defp analyze_tool_diversity do
    # Analyze tool usage patterns to encourage exploration

    tool_usage = get_tool_usage_stats(days: 7)

    unique_tools = length(Map.keys(tool_usage))
    total_calls = Enum.sum(Map.values(tool_usage))

    # Calculate entropy as a measure of diversity
    entropy = calculate_entropy(tool_usage)

    %{
      unique_tools: unique_tools,
      total_calls: total_calls,
      diversity_entropy: entropy,
      underused_tools: find_underused_tools(tool_usage)
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Feedback Loop Strategies
  # ─────────────────────────────────────────────────────────────────

  defp track_outcomes do
    # Ensure all tool calls have their outcomes tracked
    # This creates the feedback data for pattern evaluation

    untracked = count_untracked_interactions(days: 7)

    %{
      untracked_count: untracked,
      tracking_rate: if(untracked > 0, do: 0.0, else: 1.0)
    }
  end

  defp reinforce_successful_patterns do
    # Find patterns with high success rates and boost their strength

    successful =
      Pattern.list(status: :active)
      |> Enum.filter(fn p -> p.success_rate >= 0.8 and p.occurrences >= 5 end)

    reinforced =
      successful
      |> Enum.map(fn pattern ->
        # Boost strength slightly
        new_strength = min(1.0, pattern.strength * 1.05)

        Pattern.changeset(pattern, %{strength: new_strength})
        |> Repo.update()
      end)
      |> Enum.count(&match?({:ok, _}, &1))

    %{patterns_evaluated: length(successful), reinforced: reinforced}
  end

  defp store_failure_patterns do
    # Identify failure patterns and store them for avoidance

    failed_interactions = get_failed_interactions(days: 7)

    failure_patterns =
      failed_interactions
      |> group_by_failure_type()
      |> Enum.map(&create_failure_pattern/1)

    %{failures_analyzed: length(failed_interactions), patterns_stored: length(failure_patterns)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Creative Pressure Strategies
  # ─────────────────────────────────────────────────────────────────

  defp generate_exploratory_questions do
    # Generate questions that might lead to new insights
    # Based on gaps in knowledge or underexplored areas

    questions =
      [
        analyze_knowledge_gaps(),
        suggest_connection_exploration(),
        propose_pattern_investigation()
      ]
      |> List.flatten()
      |> Enum.take(5)

    %{questions_generated: length(questions), questions: questions}
  end

  defp identify_assumptions_to_challenge do
    # Find strongly held beliefs that might be worth questioning

    strong_facts =
      Memory.search_memories("", limit: 20, category: "fact")
      |> Enum.filter(fn m -> (m[:importance] || 0.5) > 0.8 end)

    challenges =
      strong_facts
      |> Enum.map(fn fact ->
        "What if '#{String.slice(fact[:content] || "", 0, 50)}...' isn't always true?"
      end)
      |> Enum.take(3)

    %{facts_reviewed: length(strong_facts), challenges_proposed: length(challenges)}
  end

  defp explore_distant_relations do
    # Find connections between seemingly unrelated concepts
    # These distant connections often lead to creative insights

    # Get concepts from different domains
    domains = ["elixir", "testing", "architecture", "debugging"]

    cross_domain_links =
      domains
      |> Enum.flat_map(fn domain1 ->
        Enum.map(domains -- [domain1], fn domain2 ->
          find_bridge_concepts(domain1, domain2)
        end)
      end)
      |> List.flatten()
      |> Enum.take(5)

    %{domains_explored: length(domains), bridges_found: length(cross_domain_links)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────

  defp get_recent_memories(opts) do
    _days = Keyword.get(opts, :days, 7)
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 100)

    Memory.search_memories("", limit: limit, category: category)
  end

  defp get_memories_with_timestamps(opts) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(e in Mimo.Brain.Engram,
      where: e.inserted_at >= ^since,
      order_by: [asc: e.inserted_at],
      select: %{id: e.id, content: e.content, inserted_at: e.inserted_at}
    )
    |> Repo.all()
  end

  defp extract_concepts(memories) do
    # Extract key concepts from memory content
    # Simple extraction based on capitalized words and quoted terms

    memories
    |> Enum.flat_map(fn memory ->
      content = memory[:content] || ""

      # Extract capitalized terms (likely module/class names)
      caps =
        Regex.scan(~r/\b[A-Z][a-zA-Z]+(?:\.[A-Z][a-zA-Z]+)*\b/, content)
        |> List.flatten()

      # Extract quoted terms
      quoted =
        Regex.scan(~r/"([^"]+)"/, content)
        |> Enum.map(&List.last/1)

      caps ++ quoted
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count >= 2 end)
    |> Enum.map(fn {concept, _} -> concept end)
  end

  defp find_linkable_pairs(concepts) do
    # Find pairs of concepts that might be related
    concepts
    |> Enum.with_index()
    |> Enum.flat_map(fn {c1, i1} ->
      concepts
      |> Enum.with_index()
      |> Enum.filter(fn {_, i2} -> i2 > i1 end)
      |> Enum.map(fn {c2, _} ->
        {c1, c2, infer_relation(c1, c2)}
      end)
    end)
    |> Enum.filter(fn {_, _, relation} -> relation != nil end)
  end

  defp infer_relation(concept1, concept2) do
    # Simple relation inference based on naming patterns
    cond do
      String.ends_with?(concept1, "Test") and
          String.replace_suffix(concept1, "Test", "") == concept2 ->
        "tests"

      String.contains?(concept1, concept2) or String.contains?(concept2, concept1) ->
        "related_to"

      true ->
        nil
    end
  end

  defp create_knowledge_link(concept1, concept2, relation) do
    # Create a triple in the semantic store using Ingestor
    Ingestor.ingest_triple(
      %{subject: concept1, predicate: relation, object: concept2},
      "emergence_amplifier"
    )
  rescue
    _ -> {:error, :link_failed}
  end

  defp extract_code_references(content) do
    # Extract potential code references (module names, function names)
    Regex.scan(~r/`([A-Z][a-zA-Z.]+)`|`([a-z_]+\/\d+)`/, content)
    |> Enum.flat_map(fn matches -> Enum.reject(matches, &is_nil/1) end)
    |> Enum.uniq()
  end

  defp link_memory_to_code(memory_id, code_ref) do
    # Create link between memory and code reference using semantic store
    # Using Ingestor instead of non-existent Synapse module
    try do
      Ingestor.ingest_triple(
        %{
          subject: "memory:#{memory_id}",
          predicate: "references",
          object: "code:#{code_ref}"
        },
        "emergence_amplifier"
      )
    rescue
      _ -> {:error, :link_failed}
    end
  end

  defp group_by_time_window(memories, opts) do
    hours = Keyword.get(opts, :hours, 2)
    window_seconds = hours * 60 * 60

    memories
    |> Enum.group_by(fn memory ->
      timestamp = memory[:inserted_at] || DateTime.utc_now()
      div(DateTime.to_unix(timestamp), window_seconds)
    end)
    |> Enum.filter(fn {_, group} -> length(group) >= 2 end)
    |> Enum.map(fn {_, group} -> group end)
  end

  defp create_temporal_chain(memories) when length(memories) < 2, do: nil

  defp create_temporal_chain(memories) do
    %{
      start: List.first(memories)[:inserted_at],
      end: List.last(memories)[:inserted_at],
      memory_count: length(memories),
      memory_ids: Enum.map(memories, & &1[:id])
    }
  end

  defp get_recent_memory_queries(_opts) do
    # Would need to track memory router queries
    # Placeholder for now
    []
  end

  defp calculate_cross_store_ratio(stores_used) do
    total = Enum.sum(Map.values(stores_used))

    if total == 0 do
      0.0
    else
      stores = Map.keys(stores_used) |> length()
      stores / max(1, total / 100)
    end
  end

  defp get_tool_usage_stats(opts) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      group_by: i.tool_name,
      select: {i.tool_name, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp calculate_entropy(frequencies) when map_size(frequencies) == 0, do: 0.0

  defp calculate_entropy(frequencies) do
    total = Enum.sum(Map.values(frequencies))

    frequencies
    |> Enum.map(fn {_, count} ->
      p = count / total
      if p > 0, do: -p * :math.log2(p), else: 0
    end)
    |> Enum.sum()
  end

  defp find_underused_tools(tool_usage) do
    # Tools that are available but rarely used
    # Would need access to tool registry
    available_tools = [
      "memory",
      "file",
      "terminal",
      "code_symbols",
      "knowledge",
      "diagnostics",
      "library",
      "search",
      "reason"
    ]

    used_tools = Map.keys(tool_usage)

    (available_tools -- used_tools)
    |> Enum.take(5)
  end

  defp count_untracked_interactions(opts) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since and is_nil(i.result_summary)
    )
    |> Repo.aggregate(:count, :id)
  end

  defp get_failed_interactions(opts) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      select: %{tool_name: i.tool_name, result_summary: i.result_summary}
    )
    |> Repo.all()
    |> Enum.filter(fn i ->
      summary = i.result_summary || ""
      String.contains?(String.downcase(summary), ["error", "failed", "exception"])
    end)
  end

  defp group_by_failure_type(failures) do
    failures
    |> Enum.group_by(fn f ->
      summary = f.result_summary || ""

      cond do
        String.contains?(summary, "timeout") -> :timeout
        String.contains?(summary, "not found") -> :not_found
        String.contains?(summary, "permission") -> :permission
        true -> :other
      end
    end)
  end

  defp create_failure_pattern({type, failures}) do
    tools = Enum.map(failures, & &1.tool_name) |> Enum.frequencies()

    %{
      failure_type: type,
      tools_affected: tools,
      count: length(failures)
    }
  end

  defp analyze_knowledge_gaps do
    # Find areas where we have few memories
    [
      "What patterns exist in error handling?",
      "What are the common debugging workflows?",
      "What architectural decisions have been made?"
    ]
  end

  defp suggest_connection_exploration do
    [
      "How do memory and knowledge graph interact?",
      "What connections exist between test and implementation files?"
    ]
  end

  defp propose_pattern_investigation do
    [
      "Are there recurring tool sequences that could be automated?",
      "What predictions have proven accurate?"
    ]
  end

  defp find_bridge_concepts(_domain1, _domain2) do
    # Would query knowledge graph for connections
    []
  end
end
