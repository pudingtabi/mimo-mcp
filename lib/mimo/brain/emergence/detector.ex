defmodule Mimo.Brain.Emergence.Detector do
  @moduledoc """
  SPEC-044: Detects emergent patterns from system interactions.

  Emergence happens when simpler components interact to produce behaviors
  that were not explicitly programmed. This module monitors:

  1. **Pattern Repetition**: Same sequences recurring across sessions
  2. **Cross-Memory Inference**: Conclusions from memory combinations
  3. **Novel Tool Chains**: Unexpected tool combinations that work
  4. **Prediction Success**: Anticipations that prove correct
  5. **Capability Transfer**: Skills from one domain to another

  ## Detection Modes

  - `:pattern_repetition` - Find action sequences that repeat
  - `:cross_memory_inference` - Find inferences from memory combo
  - `:novel_tool_chains` - Find successful tool combinations
  - `:prediction_success` - Find predictions that came true
  - `:capability_transfer` - Find skills that transferred domains

  ## Architecture

  ```
  Interaction Stream → Detector → Pattern Classification → Storage
                          ↓
                    Emergence Alerts
  ```
  """

  require Logger

  alias Mimo.Brain.{Memory, Interaction}
  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Repo
  import Ecto.Query

  @detection_modes [
    :pattern_repetition,
    :cross_memory_inference,
    :novel_tool_chains,
    :prediction_success,
    :capability_transfer
  ]

  # Minimum sequence length to consider
  @min_sequence_length 3

  # Minimum occurrences for a pattern to be significant
  @min_occurrences 3

  # Similarity threshold for sequence matching (reserved for future use)
  # @sequence_similarity_threshold 0.8

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Detects patterns for a specific mode.
  """
  @spec detect(atom(), map()) :: {:ok, [Pattern.t()]} | {:error, term()}
  def detect(mode, context \\ %{}) when mode in @detection_modes do
    case mode do
      :pattern_repetition -> detect_repetition(context)
      :cross_memory_inference -> detect_inference(context)
      :novel_tool_chains -> detect_tool_patterns(context)
      :prediction_success -> detect_predictions(context)
      :capability_transfer -> detect_transfer(context)
    end
  end

  @doc """
  Runs all detection modes and returns aggregated results.
  """
  @spec detect_all(map()) :: {:ok, map()} | {:error, term()}
  def detect_all(context \\ %{}) do
    results =
      @detection_modes
      |> Enum.map(fn mode ->
        {:ok, patterns} = detect(mode, context)
        {mode, patterns}
      end)
      |> Map.new()

    {:ok, results}
  end

  @doc """
  Analyzes recent interactions for emergent patterns.
  This is the main entry point for scheduled detection.
  """
  @spec analyze_recent(keyword()) :: {:ok, map()} | {:error, term()}
  def analyze_recent(opts \\ []) do
    days = Keyword.get(opts, :days, 7)

    Logger.info("[Emergence.Detector] Analyzing interactions from last #{days} days")

    # Get recent interactions
    interactions = get_recent_interactions(days)

    # Run detection with context
    context = %{
      interactions: interactions,
      days: days
    }

    detect_all(context)
  end

  # ─────────────────────────────────────────────────────────────────
  # Pattern Repetition Detection
  # ─────────────────────────────────────────────────────────────────

  defp detect_repetition(context) do
    days = context[:days] || 30

    # Get action sequences from recent interactions
    sequences = get_action_sequences(days)

    # Group by similarity and filter repetitions
    patterns =
      sequences
      |> group_by_similarity()
      |> filter_repetitions(@min_occurrences)
      |> Enum.map(&create_workflow_pattern/1)

    # Store or update patterns
    stored = Enum.map(patterns, &store_pattern/1)

    {:ok, stored}
  end

  defp get_action_sequences(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    # Get interactions grouped by thread
    from(i in Interaction,
      where: i.timestamp >= ^since,
      order_by: [asc: i.thread_id, asc: i.timestamp],
      select: %{
        thread_id: i.thread_id,
        tool_name: i.tool_name,
        arguments: i.arguments,
        timestamp: i.timestamp
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.thread_id)
    |> Enum.flat_map(fn {_thread_id, interactions} ->
      # Extract sequences of minimum length
      extract_sequences(interactions, @min_sequence_length)
    end)
  end

  defp extract_sequences(interactions, min_length) do
    # Use sliding window to extract all sequences
    total_length = length(interactions)

    interactions
    |> Enum.with_index()
    |> Enum.flat_map(fn {_interaction, idx} ->
      # Extract sequences starting at this position
      max_length = min(min_length + 5, total_length - idx)

      # Only generate range if min_length <= max_length
      if min_length <= max_length do
        for seq_length <- min_length..max_length do
          Enum.slice(interactions, idx, seq_length)
        end
      else
        []
      end
    end)
    |> Enum.filter(&(length(&1) >= min_length))
  end

  defp group_by_similarity(sequences) do
    # Group sequences that have similar tool patterns
    sequences
    |> Enum.group_by(fn sequence ->
      Enum.map_join(sequence, "->", & &1.tool_name)
    end)
    |> Enum.map(fn {key, seqs} ->
      %{
        signature: key,
        tools: String.split(key, "->"),
        sequences: seqs,
        count: length(seqs)
      }
    end)
  end

  defp filter_repetitions(grouped, min_count) do
    Enum.filter(grouped, fn %{count: count} -> count >= min_count end)
  end

  defp create_workflow_pattern(group) do
    %{
      type: :workflow,
      description: "Workflow pattern: #{Enum.join(group.tools, " → ")}",
      components: Enum.map(group.tools, &%{tool: &1}),
      trigger_conditions: extract_trigger_conditions(group.sequences),
      success_rate: estimate_success_rate(group.sequences),
      occurrences: group.count,
      metadata: %{
        signature: group.signature,
        domains: extract_domains(group.sequences)
      }
    }
  end

  defp extract_trigger_conditions(sequences) do
    # Analyze first tool in sequences to find common conditions
    sequences
    |> Enum.map(fn seq ->
      first = List.first(seq)
      "#{first.tool_name}(#{format_args(first.arguments)})"
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.take(3)
    |> Enum.map(fn {condition, _} -> condition end)
  end

  defp format_args(nil), do: ""
  defp format_args(args) when map_size(args) == 0, do: ""

  defp format_args(args) do
    args
    |> Map.take(["operation", "path", "query"])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v, limit: 20)}" end)
  end

  defp estimate_success_rate(sequences) do
    # Analyze sequences to determine success rate based on result summaries
    # A sequence is considered successful if none of its interactions had errors

    if Enum.empty?(sequences) do
      # Default when no data available
      0.75
    else
      successful_count =
        sequences
        |> Enum.count(fn sequence ->
          Enum.all?(sequence, fn interaction ->
            # Check if result_summary indicates success (no error keywords)
            # Use Map.get for safe access since some records may not have :result_summary
            result = Map.get(interaction, :result_summary) || ""

            not String.contains?(String.downcase(result), [
              "error",
              "failed",
              "exception",
              "timeout",
              "not found",
              "invalid"
            ])
          end)
        end)

      # Calculate success rate with minimum of 0.1 (10%) and maximum of 0.95 (95%)
      # to avoid overconfidence
      success_rate = successful_count / length(sequences)
      max(0.1, min(0.95, success_rate))
    end
  end

  defp extract_domains(sequences) do
    sequences
    |> Enum.flat_map(fn seq ->
      Enum.map(seq, fn interaction ->
        # Extract domain from tool name or arguments
        path = get_in(interaction.arguments, ["path"]) || ""

        cond do
          String.contains?(path, "lib/") -> "elixir"
          String.contains?(path, "src/") -> "source"
          String.contains?(path, "test/") -> "testing"
          true -> "general"
        end
      end)
    end)
    |> Enum.uniq()
  end

  # ─────────────────────────────────────────────────────────────────
  # Cross-Memory Inference Detection
  # ─────────────────────────────────────────────────────────────────

  defp detect_inference(context) do
    # Look for patterns where memories from different categories
    # were accessed together and led to successful outcomes

    query = context[:query] || ""

    if query == "" do
      {:ok, []}
    else
      # Search episodic and semantic memories
      episodic_results = Memory.search_memories(query, limit: 10, category: "action")
      # Note: semantic search would go through Knowledge module

      # Find cross-correlations
      inferences =
        episodic_results
        |> cross_correlate_memories()
        |> filter_novel_inferences()
        |> Enum.map(&create_inference_pattern/1)

      stored = Enum.map(inferences, &store_pattern/1)
      {:ok, stored}
    end
  end

  defp cross_correlate_memories(memories) do
    # Find memories that appear together frequently
    # and might suggest an inference
    memories
    |> Enum.with_index()
    |> Enum.flat_map(fn {mem1, idx1} ->
      memories
      |> Enum.with_index()
      |> Enum.filter(fn {_, idx2} -> idx2 > idx1 end)
      |> Enum.map(fn {mem2, _} ->
        %{
          memory1: mem1,
          memory2: mem2,
          combined_content: "#{mem1[:content]} + #{mem2[:content]}",
          categories: [mem1[:category], mem2[:category]] |> Enum.uniq()
        }
      end)
    end)
  end

  defp filter_novel_inferences(correlations) do
    # Keep only correlations that seem to yield new insights
    Enum.filter(correlations, fn correlation ->
      # Must be from different categories to be interesting
      length(correlation.categories) > 1
    end)
  end

  defp create_inference_pattern(correlation) do
    %{
      type: :inference,
      description: "Inference from: #{correlation.combined_content}",
      components: [
        %{memory1: correlation.memory1[:content]},
        %{memory2: correlation.memory2[:content]}
      ],
      trigger_conditions: correlation.categories,
      # Will be updated with feedback
      success_rate: 0.5,
      occurrences: 1,
      metadata: %{
        categories: correlation.categories
      }
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Novel Tool Chain Detection
  # ─────────────────────────────────────────────────────────────────

  defp detect_tool_patterns(context) do
    days = context[:days] || 30

    # Get tool usage patterns
    tool_chains = get_tool_chains(days)

    # Find novel combinations that worked
    novel =
      tool_chains
      |> find_successful_chains()
      |> filter_novel_combinations()
      |> Enum.map(&create_skill_pattern/1)

    stored = Enum.map(novel, &store_pattern/1)
    {:ok, stored}
  end

  defp get_tool_chains(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      order_by: [asc: i.thread_id, asc: i.timestamp],
      select: %{thread_id: i.thread_id, tool_name: i.tool_name, result_summary: i.result_summary}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.thread_id)
    |> Enum.map(fn {thread_id, interactions} ->
      %{
        thread_id: thread_id,
        tools: Enum.map(interactions, & &1.tool_name),
        success: !Enum.any?(interactions, &error_result?(&1.result_summary))
      }
    end)
  end

  defp error_result?(nil), do: false

  defp error_result?(summary) do
    summary
    |> String.downcase()
    |> String.contains?(["error", "failed", "exception", "timeout"])
  end

  defp find_successful_chains(chains) do
    Enum.filter(chains, & &1.success)
  end

  defp filter_novel_combinations(chains) do
    # A novel combination is one that uses unusual tool pairs
    # For now, just filter to chains with 3+ different tools
    chains
    |> Enum.filter(fn chain ->
      chain.tools |> Enum.uniq() |> length() >= 3
    end)
  end

  defp create_skill_pattern(chain) do
    unique_tools = Enum.uniq(chain.tools)

    %{
      type: :skill,
      description: "Skill: effective use of #{Enum.join(unique_tools, ", ")}",
      components: Enum.map(unique_tools, &%{tool: &1}),
      trigger_conditions: [],
      # It was successful
      success_rate: 1.0,
      occurrences: 1,
      metadata: %{
        thread_id: chain.thread_id,
        full_sequence: chain.tools
      }
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Prediction Success Detection
  # ─────────────────────────────────────────────────────────────────

  defp detect_predictions(_context) do
    # Look for memories that were predictions and later verified
    # This requires memories to be tagged as predictions

    predictions =
      Memory.search_memories("predict OR expect OR anticipate",
        limit: 20,
        category: "plan"
      )

    verified =
      predictions
      |> Enum.filter(&prediction_verified?/1)
      |> Enum.map(&create_heuristic_pattern/1)

    stored = Enum.map(verified, &store_pattern/1)
    {:ok, stored}
  end

  defp prediction_verified?(prediction) do
    # Check if there's a later memory that confirms the prediction
    # This is a simplified check - would need more sophisticated matching
    content = prediction[:content] || ""

    # Search for confirmation memories
    confirmations = Memory.search_memories("confirmed #{content}", limit: 5)
    length(confirmations) > 0
  end

  defp create_heuristic_pattern(prediction) do
    %{
      type: :heuristic,
      description: "Validated prediction: #{prediction[:content]}",
      components: [%{prediction: prediction[:content]}],
      trigger_conditions: [],
      success_rate: 1.0,
      occurrences: 1,
      metadata: %{
        original_memory_id: prediction[:id],
        verified_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Capability Transfer Detection
  # ─────────────────────────────────────────────────────────────────

  defp detect_transfer(context) do
    # Look for patterns that were learned in one domain and
    # successfully applied in another

    days = context[:days] || 30

    # Get patterns grouped by domain
    patterns_by_domain = get_patterns_by_domain(days)

    # Find transfers
    transfers =
      patterns_by_domain
      |> find_cross_domain_transfers()
      |> Enum.map(&create_transfer_pattern/1)

    stored = Enum.map(transfers, &store_pattern/1)
    {:ok, stored}
  end

  defp get_patterns_by_domain(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    # Get interactions with domain info
    from(i in Interaction,
      where: i.timestamp >= ^since,
      select: %{tool_name: i.tool_name, arguments: i.arguments}
    )
    |> Repo.all()
    |> Enum.group_by(fn interaction ->
      path = get_in(interaction.arguments, ["path"]) || ""
      infer_domain(path)
    end)
  end

  defp infer_domain(path) do
    cond do
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") -> "elixir"
      String.ends_with?(path, ".ts") or String.ends_with?(path, ".tsx") -> "typescript"
      String.ends_with?(path, ".py") -> "python"
      String.ends_with?(path, ".rs") -> "rust"
      String.ends_with?(path, ".go") -> "go"
      String.contains?(path, "test") -> "testing"
      String.contains?(path, "doc") -> "documentation"
      true -> "general"
    end
  end

  defp find_cross_domain_transfers(patterns_by_domain) do
    _domains = Map.keys(patterns_by_domain)

    # Find tool patterns that appear in multiple domains
    all_patterns =
      patterns_by_domain
      |> Enum.flat_map(fn {domain, interactions} ->
        interactions
        |> Enum.map(& &1.tool_name)
        |> Enum.frequencies()
        |> Enum.map(fn {tool, count} -> {domain, tool, count} end)
      end)

    # Group by tool and filter those appearing in 2+ domains
    all_patterns
    |> Enum.group_by(fn {_domain, tool, _count} -> tool end)
    |> Enum.filter(fn {_tool, occurrences} ->
      occurrences
      |> Enum.map(fn {domain, _, _} -> domain end)
      |> Enum.uniq()
      |> length() >= 2
    end)
    |> Enum.map(fn {tool, occurrences} ->
      %{
        tool: tool,
        domains: Enum.map(occurrences, fn {domain, _, _} -> domain end) |> Enum.uniq(),
        total_count: Enum.map(occurrences, fn {_, _, count} -> count end) |> Enum.sum()
      }
    end)
  end

  defp create_transfer_pattern(transfer) do
    %{
      type: :skill,
      description:
        "Cross-domain skill: #{transfer.tool} across #{Enum.join(transfer.domains, ", ")}",
      components: [%{tool: transfer.tool, domains: transfer.domains}],
      trigger_conditions: transfer.domains,
      success_rate: 0.8,
      occurrences: transfer.total_count,
      metadata: %{
        domains: transfer.domains,
        transfer_type: "capability_transfer"
      }
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  defp get_recent_interactions(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      order_by: [desc: i.timestamp]
    )
    |> Repo.all()
  end

  defp store_pattern(pattern_attrs) do
    case Pattern.find_or_create(pattern_attrs) do
      {:ok, pattern} -> pattern
      {:error, _} -> nil
    end
  end
end
