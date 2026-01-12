defmodule Mimo.Brain.Emergence.Prober do
  @moduledoc """
  SPEC-044 Phase 4.4: Active Probing for Capability Discovery

  Proactively tests patterns against generated tasks to:
  1. Validate pattern effectiveness
  2. Discover new capabilities
  3. Strengthen successful patterns
  4. Build a capability taxonomy

  Based on research:
  - ACD (arXiv:2502.07577): Self-exploration for capability discovery
  - Self-Developing (arXiv:2410.15639): Algorithm Factory pattern

  ## Capability Taxonomy

  Patterns are classified into capability domains:

  - `:code_analysis` - Understanding code structure, finding bugs
  - `:code_generation` - Writing new code, refactoring
  - `:debugging` - Fixing errors, diagnosing issues
  - `:research` - Information gathering, web search
  - `:file_operations` - Reading, writing, editing files
  - `:memory_management` - Storing, retrieving context
  - `:reasoning` - Planning, decision making
  - `:communication` - Explaining, summarizing

  ## Probe Types

  - `:validation` - Test if pattern works for its claimed use case
  - `:boundary` - Find edge cases where pattern fails
  - `:generalization` - Test pattern on similar but new tasks
  - `:composition` - Test pattern combined with others

  ## Example

      # Get patterns ready for probing
      Prober.probe_candidates(limit: 5)

      # Generate probe task for a pattern
      Prober.generate_probe_task(pattern, type: :validation)

      # Execute probe and record result
      Prober.probe_pattern(pattern, task)

      # Get capability summary
      Prober.capability_summary()
  """
  require Logger

  alias Mimo.Brain.Emergence.Pattern

  # The capability taxonomy defines domains that patterns can belong to.
  # Each domain has associated tool categories and task types.
  @capability_domains %{
    code_analysis: %{
      description: "Understanding code structure, finding definitions, analyzing dependencies",
      tools: ["code", "file"],
      keywords: ["definition", "reference", "symbol", "analyze", "understand"]
    },
    code_generation: %{
      description: "Writing new code, refactoring, implementing features",
      tools: ["file", "code"],
      keywords: ["create", "write", "implement", "generate", "refactor"]
    },
    debugging: %{
      description: "Fixing errors, diagnosing issues, troubleshooting",
      tools: ["code", "terminal", "file"],
      keywords: ["fix", "error", "debug", "diagnose", "troubleshoot", "issue"]
    },
    research: %{
      description: "Information gathering, web search, documentation lookup",
      tools: ["web", "memory"],
      keywords: ["search", "find", "lookup", "research", "documentation"]
    },
    file_operations: %{
      description: "Reading, writing, editing, organizing files",
      tools: ["file"],
      keywords: ["read", "write", "edit", "move", "copy", "delete"]
    },
    memory_management: %{
      description: "Storing context, retrieving past information, knowledge management",
      tools: ["memory", "knowledge"],
      keywords: ["remember", "store", "recall", "context", "history"]
    },
    reasoning: %{
      description: "Planning tasks, making decisions, problem decomposition",
      tools: ["cognitive", "reason"],
      keywords: ["plan", "decide", "think", "analyze", "strategy"]
    },
    communication: %{
      description: "Explaining concepts, summarizing information, documenting",
      tools: ["memory"],
      keywords: ["explain", "summarize", "document", "describe", "clarify"]
    }
  }

  @probe_types [:validation, :boundary, :generalization, :composition]

  @doc """
  Get patterns that are good candidates for probing.

  Candidates are active patterns that:
  - Have been seen recently (within last 7 days)
  - Have moderate strength (0.3-0.8) - not too weak or too strong
  - Haven't been probed recently
  """
  @spec probe_candidates(keyword()) :: list(map())
  def probe_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_occurrences = Keyword.get(opts, :min_occurrences, 3)

    Pattern.list(status: :active, limit: 100)
    |> Enum.filter(fn p ->
      p.occurrences >= min_occurrences and
        p.strength >= 0.3 and
        p.strength <= 0.85 and
        recent?(p.last_seen, days: 7)
    end)
    |> Enum.map(fn p ->
      domain = classify_pattern_domain(p)

      %{
        id: p.id,
        description: p.description,
        type: p.type,
        domain: domain,
        strength: p.strength,
        success_rate: p.success_rate,
        occurrences: p.occurrences,
        probe_priority: calculate_probe_priority(p, domain)
      }
    end)
    |> Enum.sort_by(& &1.probe_priority, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Classify a pattern into a capability domain based on its description and tools.
  """
  @spec classify_pattern_domain(Pattern.t()) :: atom()
  def classify_pattern_domain(pattern) do
    description = String.downcase(pattern.description || "")

    # Extract tools from components (each component may have a "tool" key)
    tools = extract_tools_from_components(pattern.components || [])

    # Score each domain
    scores =
      @capability_domains
      |> Enum.map(fn {domain, config} ->
        tool_score =
          tools
          |> Enum.count(fn tool -> Enum.member?(config.tools, tool) end)
          |> Kernel./(max(1, length(tools)))

        keyword_score =
          config.keywords
          |> Enum.count(fn kw -> String.contains?(description, kw) end)
          |> Kernel./(max(1, length(config.keywords)))

        {domain, tool_score * 0.6 + keyword_score * 0.4}
      end)

    # Return highest scoring domain, default to :reasoning
    case Enum.max_by(scores, fn {_, score} -> score end) do
      {domain, score} when score > 0.1 -> domain
      _ -> :reasoning
    end
  end

  # Extract tool names from pattern components
  defp extract_tools_from_components(components) when is_list(components) do
    components
    |> Enum.map(fn
      %{"tool" => tool} when is_binary(tool) -> tool
      %{tool: tool} when is_binary(tool) -> tool
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_tools_from_components(_), do: []

  @doc """
  Generate a probe task for testing a pattern.

  The probe task is designed to validate the pattern's effectiveness.
  """
  @spec generate_probe_task(Pattern.t() | map(), keyword()) :: map()
  def generate_probe_task(pattern, opts \\ []) do
    probe_type = Keyword.get(opts, :type, :validation)
    domain = classify_pattern_domain(pattern)

    base_task = %{
      pattern_id: pattern.id,
      probe_type: probe_type,
      domain: domain,
      created_at: DateTime.utc_now()
    }

    case probe_type do
      :validation ->
        generate_validation_task(pattern, domain, base_task)

      :boundary ->
        generate_boundary_task(pattern, domain, base_task)

      :generalization ->
        generate_generalization_task(pattern, domain, base_task)

      :composition ->
        generate_composition_task(pattern, domain, base_task)
    end
  end

  @doc """
  Execute a probe task against a pattern and record the result.

  This is a dry run - it doesn't actually execute tools but simulates
  what would happen based on pattern characteristics.
  """
  @spec probe_pattern(Pattern.t() | map(), map()) :: map()
  def probe_pattern(pattern, task) do
    # Simulate probe execution
    # In a full implementation, this would actually execute the tools
    simulated_success = simulate_probe_success(pattern, task)

    result = %{
      pattern_id: pattern.id,
      task: task,
      success: simulated_success,
      probed_at: DateTime.utc_now(),
      confidence: calculate_probe_confidence(pattern, task, simulated_success)
    }

    # Log the probe result
    Logger.debug(
      "[Prober] Probed pattern #{pattern.id}: #{if simulated_success, do: "SUCCESS", else: "FAILED"}"
    )

    result
  end

  @doc """
  Get a summary of capabilities across all patterns.

  Groups patterns by domain and calculates aggregate metrics.
  """
  @spec capability_summary() :: map()
  def capability_summary do
    patterns = Pattern.list(status: :active, limit: 500)

    domain_stats =
      patterns
      |> Enum.group_by(&classify_pattern_domain/1)
      |> Enum.map(fn {domain, domain_patterns} ->
        config = Map.get(@capability_domains, domain, %{description: "Unknown"})

        {domain,
         %{
           description: config[:description] || "Unknown domain",
           pattern_count: length(domain_patterns),
           avg_strength: average(Enum.map(domain_patterns, & &1.strength)),
           avg_success_rate: average(Enum.map(domain_patterns, & &1.success_rate)),
           total_occurrences: Enum.sum(Enum.map(domain_patterns, & &1.occurrences)),
           strongest_pattern: strongest_pattern(domain_patterns)
         }}
      end)
      |> Enum.into(%{})

    %{
      domains: domain_stats,
      total_patterns: length(patterns),
      domain_count: map_size(domain_stats),
      strongest_domains: top_domains(domain_stats, 3),
      weakest_domains: weak_domains(domain_stats, 3),
      updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Get all capability domains with their definitions.
  """
  @spec capability_domains() :: map()
  def capability_domains, do: @capability_domains

  @doc """
  Get valid probe types.
  """
  @spec probe_types() :: list(atom())
  def probe_types, do: @probe_types

  # Private functions

  defp recent?(nil, _opts), do: false

  defp recent?(datetime, opts) do
    days = Keyword.get(opts, :days, 7)
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)
    DateTime.compare(datetime, cutoff) == :gt
  end

  defp calculate_probe_priority(pattern, _domain) do
    # Higher priority for:
    # - Moderate strength (0.5-0.7 is ideal for probing)
    # - More occurrences (more data to learn from)
    # - Lower success rate (more room for improvement)

    strength_score = 1.0 - abs(pattern.strength - 0.6) * 2
    occurrence_score = min(1.0, pattern.occurrences / 20)
    improvement_potential = 1.0 - pattern.success_rate

    (strength_score * 0.3 + occurrence_score * 0.3 + improvement_potential * 0.4)
    |> Float.round(3)
  end

  defp generate_validation_task(pattern, _domain, base_task) do
    tools = extract_tools_from_components(pattern.components || [])

    Map.merge(base_task, %{
      task_type: :validation,
      description: "Validate that pattern works for its intended use case",
      expected_tools: tools,
      success_criteria: "Pattern should successfully complete its described behavior"
    })
  end

  defp generate_boundary_task(_pattern, _domain, base_task) do
    Map.merge(base_task, %{
      task_type: :boundary,
      description: "Find edge cases where pattern may fail",
      variations: [
        "empty input",
        "very large input",
        "special characters",
        "missing dependencies"
      ],
      success_criteria: "Identify at least one boundary condition"
    })
  end

  defp generate_generalization_task(_pattern, domain, base_task) do
    similar_domains =
      @capability_domains
      |> Enum.filter(fn {d, _} -> d != domain end)
      |> Enum.take_random(2)
      |> Enum.map(fn {d, _} -> d end)

    Map.merge(base_task, %{
      task_type: :generalization,
      description: "Test pattern on similar tasks in related domains",
      test_domains: similar_domains,
      success_criteria: "Pattern works in at least one related domain"
    })
  end

  defp generate_composition_task(_pattern, _domain, base_task) do
    Map.merge(base_task, %{
      task_type: :composition,
      description: "Test pattern combined with other patterns",
      composition_strategy: :sequential,
      success_criteria: "Pattern works well when composed with others"
    })
  end

  defp simulate_probe_success(pattern, task) do
    # Simulate success based on pattern characteristics
    base_probability = pattern.success_rate

    # Adjust based on probe type
    type_modifier =
      case task.probe_type do
        :validation -> 1.0
        :boundary -> 0.6
        :generalization -> 0.7
        :composition -> 0.8
      end

    probability = base_probability * type_modifier
    :rand.uniform() < probability
  end

  defp calculate_probe_confidence(pattern, _task, success) do
    # Higher confidence with more occurrences
    data_confidence = min(1.0, pattern.occurrences / 15)

    # Adjust based on success
    result_modifier = if success, do: 1.0, else: 0.7

    (data_confidence * result_modifier) |> Float.round(3)
  end

  defp average([]), do: 0.0

  defp average(values) do
    (Enum.sum(values) / length(values))
    |> Float.round(3)
  end

  defp strongest_pattern([]), do: nil

  defp strongest_pattern(patterns) do
    pattern = Enum.max_by(patterns, & &1.strength)
    %{id: pattern.id, description: pattern.description, strength: pattern.strength}
  end

  defp top_domains(domain_stats, n) do
    domain_stats
    |> Enum.sort_by(fn {_, stats} -> stats.avg_strength end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {domain, _} -> domain end)
  end

  defp weak_domains(domain_stats, n) do
    domain_stats
    |> Enum.filter(fn {_, stats} -> stats.pattern_count > 0 end)
    |> Enum.sort_by(fn {_, stats} -> stats.avg_strength end, :asc)
    |> Enum.take(n)
    |> Enum.map(fn {domain, _} -> domain end)
  end
end
