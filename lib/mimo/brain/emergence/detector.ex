defmodule Mimo.Brain.Emergence.Detector do
  @moduledoc """
  SPEC-044: Counts and tracks patterns from system interactions.

  NOTE: The term "emergence" is aspirational. This module performs pattern
  counting and frequency analysis, not true emergence detection. The actual
  implementation uses GROUP BY and string matching. See docs/ANTI-SLOP.md.

  What this module actually does:

  1. **Pattern Repetition**: Counts tool call sequences (GROUP BY tool_name)
  2. **Cross-Memory Pairing**: Creates pairs from different memory stores
  3. **Tool Chain Counting**: Counts successful tool combinations
  4. **Prediction Tracking**: String-matches "confirmed" in content
  5. **Domain Tagging**: Matches keywords to domains

  ## Detection Modes

  - `:pattern_repetition` - Group and count action sequences
  - `:cross_memory_inference` - Pair memories from different stores
  - `:novel_tool_chains` - Count tool combinations
  - `:prediction_success` - String-match prediction confirmations
  - `:capability_transfer` - Match domain keywords

  ## Architecture

  ```
  Interaction Stream → Counter → Pattern Storage
                          ↓
                    Frequency Alerts
  ```
  """

  require Logger

  alias Mimo.Brain.Emergence.Pattern
  alias Mimo.Brain.{Interaction, Memory, LLM}
  alias Mimo.Repo
  alias Mimo.Synapse.Graph
  alias Mimo.Vector.Math, as: VectorMath
  import Ecto.Query

  @detection_modes [
    :pattern_repetition,
    :cross_memory_inference,
    :novel_tool_chains,
    :prediction_success,
    :capability_transfer,
    # Phase 4: E1 - LLM-enhanced pattern detection
    :semantic_clustering,
    # Phase 4: E3 - Cross-session pattern tracking
    :cross_session
  ]

  # Minimum sequence length to consider
  @min_sequence_length 3

  # Minimum occurrences for a pattern to be significant
  @min_occurrences 3

  # Phase 4 E1: Semantic clustering thresholds
  @semantic_similarity_threshold 0.85
  @min_cluster_size 3

  # Phase 4 E3: Cross-session pattern thresholds
  @min_sessions_for_pattern 2
  @session_window_days 7

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
      :semantic_clustering -> detect_semantic_clusters(context)
      :cross_session -> detect_cross_session(context)
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
  Returns the list of available detection modes.

  Used by MetaLearner to understand what detection strategies are available.
  """
  @spec available_modes() :: [atom()]
  def available_modes do
    @detection_modes
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
    # Phase 3: Cross-memory inference - find patterns across different memory stores
    # Look for patterns where memories from different categories/stores
    # were accessed together and led to successful outcomes

    query = context[:query] || ""

    if query == "" do
      {:ok, []}
    else
      # Query multiple memory stores in parallel
      memory_tasks = [
        Task.async(fn ->
          {:episodic, Memory.search_memories(query, limit: 8, category: "action")}
        end),
        Task.async(fn -> {:facts, Memory.search_memories(query, limit: 8, category: "fact")} end),
        Task.async(fn ->
          {:observations, Memory.search_memories(query, limit: 5, category: "observation")}
        end),
        Task.async(fn -> {:knowledge, gather_knowledge_nodes(query)} end)
      ]

      # Collect results with timeout
      store_results =
        memory_tasks
        |> Task.yield_many(3000)
        |> Enum.map(fn {task, result} ->
          case result do
            {:ok, {store, data}} ->
              {store, data}

            _ ->
              Task.shutdown(task, :brutal_kill)
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      # Find cross-store patterns
      inferences =
        store_results
        |> cross_correlate_stores()
        |> filter_novel_inferences()
        |> Enum.map(&create_inference_pattern/1)

      stored = Enum.map(inferences, &store_pattern/1)
      {:ok, stored}
    end
  end

  # Gather knowledge graph nodes related to query
  defp gather_knowledge_nodes(query) do
    try do
      case Graph.search_nodes(query, limit: 5) do
        nodes when is_list(nodes) ->
          Enum.map(nodes, fn n ->
            %{content: n.name || n.id, category: "knowledge", type: n.type}
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  # Cross-correlate memories from different stores
  defp cross_correlate_stores(store_results) do
    all_memories =
      store_results
      |> Enum.flat_map(fn {store, memories} ->
        memories
        |> List.wrap()
        |> Enum.map(fn m -> Map.put(m, :source_store, store) end)
      end)

    # Find pairs from DIFFERENT stores
    all_memories
    |> Enum.with_index()
    |> Enum.flat_map(fn {mem1, idx1} ->
      all_memories
      |> Enum.with_index()
      |> Enum.filter(fn {mem2, idx2} ->
        idx2 > idx1 and mem1[:source_store] != mem2[:source_store]
      end)
      |> Enum.map(fn {mem2, _} ->
        %{
          memory1: mem1,
          memory2: mem2,
          combined_content: "#{mem1[:content]} + #{mem2[:content]}",
          categories: [mem1[:category], mem2[:category]] |> Enum.uniq(),
          stores: [mem1[:source_store], mem2[:source_store]] |> Enum.uniq()
        }
      end)
    end)
    # Limit to prevent explosion
    |> Enum.take(20)
  end

  defp filter_novel_inferences(correlations) do
    # Keep only correlations that seem to yield new insights
    Enum.filter(correlations, fn correlation ->
      # Must be from different categories OR different stores to be interesting
      different_categories = length(correlation.categories) > 1
      different_stores = length(Map.get(correlation, :stores, [])) > 1
      different_categories or different_stores
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
    # Novel combinations use 3+ different tools in sequence.
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
    confirmations != []
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
  # Phase 4 E1: Semantic Pattern Clustering
  # Uses embeddings to find semantically similar interaction patterns
  # ─────────────────────────────────────────────────────────────────

  # Detects patterns using semantic clustering with embeddings.
  #
  # Unlike string-based grouping, this finds patterns that are
  # semantically similar even if they use different tool names.
  #
  # Example: "read file then edit" and "file read operation followed by write"
  # would be clustered together despite different terminology.
  defp detect_semantic_clusters(context) do
    days = context[:days] || 30
    limit = context[:limit] || 100

    Logger.info("[Emergence.Detector] Running semantic clustering (Phase 4 E1)")

    # Get recent interactions with their context
    interactions = get_interactions_for_clustering(days, limit)

    if length(interactions) < @min_cluster_size do
      Logger.debug("[Emergence.Detector] Not enough interactions for clustering")
      {:ok, []}
    else
      # Build semantic signatures and get embeddings
      case build_semantic_signatures(interactions) do
        {:ok, signatures_with_embeddings} ->
          # Cluster by semantic similarity
          clusters = cluster_by_similarity(signatures_with_embeddings)

          # Convert clusters to patterns
          patterns =
            clusters
            |> Enum.filter(fn c -> length(c.members) >= @min_cluster_size end)
            |> Enum.map(&create_semantic_pattern/1)
            |> Enum.map(&store_pattern/1)
            |> Enum.reject(&is_nil/1)

          Logger.info("[Emergence.Detector] Found #{length(patterns)} semantic patterns")
          {:ok, patterns}

        {:error, reason} ->
          Logger.warning("[Emergence.Detector] Semantic clustering failed: #{inspect(reason)}")
          {:ok, []}
      end
    end
  end

  defp get_interactions_for_clustering(days, limit) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      order_by: [desc: i.timestamp],
      limit: ^limit,
      select: %{
        id: i.id,
        tool_name: i.tool_name,
        arguments: i.arguments,
        result_summary: i.result_summary,
        timestamp: i.timestamp,
        thread_id: i.thread_id
      }
    )
    |> Repo.all()
  end

  defp build_semantic_signatures(interactions) do
    # Build semantic signatures that capture the essence of each interaction
    signatures =
      interactions
      |> Enum.map(fn i ->
        # Create a text signature combining tool, args, and result
        args_text =
          case i.arguments do
            nil ->
              ""

            args when is_map(args) ->
              args
              # Limit to avoid huge signatures
              |> Enum.take(3)
              |> Enum.map(fn {k, v} -> "#{k}: #{truncate_value(v)}" end)
              |> Enum.join(", ")

            _ ->
              ""
          end

        signature =
          "#{i.tool_name} #{args_text} #{truncate_value(i.result_summary || "")}"
          |> String.trim()
          # Limit signature length
          |> String.slice(0, 500)

        %{
          id: i.id,
          tool_name: i.tool_name,
          signature: signature,
          timestamp: i.timestamp,
          thread_id: i.thread_id
        }
      end)

    # Get embeddings for all signatures in batch
    texts = Enum.map(signatures, & &1.signature)

    case LLM.get_embeddings(texts) do
      {:ok, embeddings} ->
        # Zip signatures with embeddings
        with_embeddings =
          Enum.zip(signatures, embeddings)
          |> Enum.map(fn {sig, emb} -> Map.put(sig, :embedding, emb) end)

        {:ok, with_embeddings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate_value(value) when is_binary(value), do: String.slice(value, 0, 100)
  defp truncate_value(value) when is_map(value), do: inspect(value) |> String.slice(0, 100)
  defp truncate_value(value), do: inspect(value) |> String.slice(0, 100)

  defp cluster_by_similarity(signatures) do
    # Simple greedy clustering: assign each signature to nearest cluster
    # or create new cluster if no similar one exists

    Enum.reduce(signatures, [], fn sig, clusters ->
      case find_similar_cluster(sig, clusters) do
        nil ->
          # Create new cluster
          [
            %{
              centroid: sig.embedding,
              members: [sig],
              tools: [sig.tool_name]
            }
            | clusters
          ]

        {cluster_idx, cluster} ->
          # Add to existing cluster and update centroid
          new_members = [sig | cluster.members]
          new_centroid = compute_centroid(Enum.map(new_members, & &1.embedding))
          new_tools = Enum.uniq([sig.tool_name | cluster.tools])

          updated_cluster = %{
            cluster
            | members: new_members,
              centroid: new_centroid,
              tools: new_tools
          }

          List.replace_at(clusters, cluster_idx, updated_cluster)
      end
    end)
  end

  defp find_similar_cluster(sig, clusters) do
    clusters
    |> Enum.with_index()
    |> Enum.find_value(fn {cluster, idx} ->
      similarity = VectorMath.cosine_similarity(sig.embedding, cluster.centroid)

      if similarity >= @semantic_similarity_threshold do
        {idx, cluster}
      else
        nil
      end
    end)
  end

  defp compute_centroid(embeddings) do
    # Average of all embeddings
    count = length(embeddings)
    dim = length(List.first(embeddings))

    sums =
      Enum.reduce(embeddings, List.duplicate(0.0, dim), fn emb, acc ->
        Enum.zip(emb, acc)
        |> Enum.map(fn {a, b} -> a + b end)
      end)

    Enum.map(sums, &(&1 / count))
  end

  defp create_semantic_pattern(cluster) do
    # Create a pattern from the cluster
    tool_summary =
      cluster.tools
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> count end, :desc)
      |> Enum.take(3)
      |> Enum.map(fn {tool, _} -> tool end)
      |> Enum.join(", ")

    member_signatures =
      cluster.members
      |> Enum.take(3)
      |> Enum.map(& &1.signature)

    %{
      type: :semantic_cluster,
      description: "Semantic pattern: #{tool_summary} (#{length(cluster.members)} occurrences)",
      components: Enum.map(cluster.tools, fn tool -> %{tool: tool} end),
      trigger_conditions: member_signatures,
      # Default, will be updated by usage tracking
      success_rate: 0.75,
      occurrences: length(cluster.members),
      metadata: %{
        cluster_size: length(cluster.members),
        tools: cluster.tools,
        detection_method: "semantic_clustering",
        sample_signatures: Enum.take(member_signatures, 3)
      }
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Phase 4 E3: Cross-Session Pattern Detection
  # ─────────────────────────────────────────────────────────────────

  # Detects patterns that persist across multiple sessions.
  #
  # Cross-session patterns are especially valuable because they represent
  # behaviors that are consistently useful, not just one-time solutions.
  #
  # This analyzes:
  # 1. Tool sequences that recur across different sessions
  # 2. Time-of-day patterns (e.g., "always runs tests before committing")
  # 3. Context-switching patterns (switching between domains)
  defp detect_cross_session(context) do
    days = Map.get(context, :window_days, @session_window_days)
    min_sessions = Map.get(context, :min_sessions, @min_sessions_for_pattern)

    Logger.debug(
      "[Emergence.Detector] Running cross-session pattern detection (#{days} day window)"
    )

    # Get interactions grouped by session
    interactions = get_interactions_with_sessions(days)

    # Group by session ID
    by_session = group_by_session(interactions)

    # Skip if not enough sessions
    if map_size(by_session) < min_sessions do
      Logger.debug("[Emergence.Detector] Not enough sessions for cross-session detection")
      {:ok, []}
    else
      # Find patterns that occur in multiple sessions
      cross_session_patterns = find_recurring_patterns(by_session, min_sessions)

      # Store the detected patterns
      patterns =
        cross_session_patterns
        |> Enum.map(&create_cross_session_pattern/1)
        |> Enum.map(&store_pattern/1)
        |> Enum.reject(&is_nil/1)

      Logger.info("[Emergence.Detector] Detected #{length(patterns)} cross-session patterns")
      {:ok, patterns}
    end
  end

  defp get_interactions_with_sessions(days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    from(i in Interaction,
      where: i.timestamp >= ^since,
      order_by: [asc: i.timestamp],
      select: %{
        tool_name: i.tool_name,
        timestamp: i.timestamp,
        # Use thread_id as session proxy
        thread_id: i.thread_id,
        consolidated: i.consolidated
      }
    )
    |> Repo.all()
  end

  defp group_by_session(interactions) do
    interactions
    |> Enum.group_by(fn i ->
      # Use thread_id if available, otherwise derive from timestamp
      i.thread_id || derive_session_id(i.timestamp)
    end)
  end

  # Derive a session ID based on time gaps (>30 min gap = new session)
  defp derive_session_id(timestamp) do
    # Simple date-based session (one session per day)
    Date.to_iso8601(DateTime.to_date(timestamp))
  end

  defp find_recurring_patterns(by_session, min_sessions) do
    # Extract tool sequences from each session
    session_sequences =
      by_session
      |> Enum.map(fn {session_id, interactions} ->
        tools = Enum.map(interactions, & &1.tool_name)
        success_rate = calculate_session_success_rate(interactions)
        {session_id, tools, success_rate}
      end)

    # Find n-gram patterns that appear in multiple sessions
    # We look for 2-gram and 3-gram patterns
    all_ngrams =
      session_sequences
      |> Enum.flat_map(fn {session_id, tools, success_rate} ->
        ngrams_2 = extract_ngrams(tools, 2) |> Enum.map(&{&1, session_id, success_rate, 2})
        ngrams_3 = extract_ngrams(tools, 3) |> Enum.map(&{&1, session_id, success_rate, 3})
        ngrams_2 ++ ngrams_3
      end)

    # Group by ngram and find those in multiple sessions
    all_ngrams
    |> Enum.group_by(fn {ngram, _, _, _} -> ngram end)
    |> Enum.filter(fn {_ngram, occurrences} ->
      unique_sessions =
        occurrences |> Enum.map(fn {_, session_id, _, _} -> session_id end) |> Enum.uniq()

      length(unique_sessions) >= min_sessions
    end)
    |> Enum.map(fn {ngram, occurrences} ->
      sessions = Enum.map(occurrences, fn {_, sid, _, _} -> sid end) |> Enum.uniq()

      avg_success =
        occurrences
        |> Enum.map(fn {_, _, sr, _} -> sr end)
        |> Enum.sum()
        |> Kernel./(length(occurrences))

      n = occurrences |> List.first() |> elem(3)

      %{
        tools: ngram,
        sessions: sessions,
        session_count: length(sessions),
        occurrences: length(occurrences),
        avg_success_rate: Float.round(avg_success, 3),
        n: n
      }
    end)
    |> Enum.sort_by(& &1.session_count, :desc)
  end

  defp extract_ngrams(tools, n) when is_list(tools) and n > 0 do
    if length(tools) < n do
      []
    else
      tools
      |> Enum.chunk_every(n, 1, :discard)
    end
  end

  defp calculate_session_success_rate(interactions) do
    total = length(interactions)

    if total == 0 do
      0.0
    else
      # Use consolidation as proxy for "success" - consolidated interactions are significant
      consolidated = Enum.count(interactions, & &1.consolidated)
      consolidated / total
    end
  end

  defp create_cross_session_pattern(pattern_data) do
    tool_sequence = Enum.join(pattern_data.tools, " → ")

    %{
      type: :workflow,
      description:
        "Cross-session pattern: #{tool_sequence} (#{pattern_data.session_count} sessions)",
      components: Enum.map(pattern_data.tools, fn tool -> %{"tool" => tool} end),
      trigger_conditions: ["multi-session", "recurring"],
      success_rate: pattern_data.avg_success_rate,
      occurrences: pattern_data.occurrences,
      metadata: %{
        detection_method: "cross_session",
        session_count: pattern_data.session_count,
        sessions: Enum.take(pattern_data.sessions, 5),
        n_gram_size: pattern_data.n,
        cross_session: true
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
