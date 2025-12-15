defmodule Mimo.Tools.Dispatchers.PrepareContext do
  @moduledoc """
  Compound cognitive tool: Smart Context Preparation.

  SPEC-036: Aggregates context from multiple Mimo cognitive systems in parallel
  to give any model (especially small ones) a "photographic memory" of the project.

  SPEC-051: Supports tiered context delivery for optimized token usage:
  - Tier 1 (Essential): 5-10% - Critical for immediate task execution
  - Tier 2 (Supporting): 15-20% - Important background context
  - Tier 3 (Background): Remaining - Available on-demand

  This is the FOUNDATION for small model capability enhancement. By providing
  rich, relevant context BEFORE the model starts reasoning, we compensate for
  limited context windows and parametric knowledge.

  Pipeline:
  1. Parse query to extract key entities/concepts
  2. Parallel gather from: memory, knowledge, code_symbols, library, recent actions
  3. Score and classify into tiers (SPEC-051)
  4. Return structured context with budget-aware truncation

  This tool embodies the principle: "Context is Power"
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Brain.HybridScorer
  alias Mimo.Context.BudgetAllocator
  alias Mimo.Tools.Dispatchers.{Code, Knowledge, Library}
  alias Mimo.Cognitive.KnowledgeTransfer
  alias Mimo.TaskHelper

  @doc """
  Dispatch prepare_context operation.

  ## Options
    - query: The task/query to gather context for (required)
    - max_tokens: Approximate max tokens for output (default: 2000)
    - sources: List of sources to query (default: all)
               Options: ["memory", "knowledge", "code", "library", "actions"]
    - include_scores: Include relevance scores in output (default: false)
    
  ## SPEC-051 Tiered Options
    - tiered: Enable tiered context delivery (default: false)
    - model_type: Model type for budget allocation ("haiku", "opus", etc.)
    - include_tier3: Include Tier 3 in initial response (default: false)
    - predictive: Enable predictive loading suggestions (default: false)
  """
  def dispatch(args) do
    query = args["query"]

    if is_nil(query) or query == "" do
      {:error, "query is required for prepare_context"}
    else
      run_context_gathering(query, args)
    end
  end

  # ==========================================================================
  # CONTEXT GATHERING PIPELINE
  # ==========================================================================

  defp run_context_gathering(query, args) do
    Logger.info("[PrepareContext] Gathering context for: #{String.slice(query, 0, 50)}...")
    start_time = System.monotonic_time(:millisecond)

    # Parse query to extract key entities
    entities = extract_entities(query)
    Logger.debug("[PrepareContext] Extracted entities: #{inspect(entities)}")

    # Determine which sources to query
    sources = Map.get(args, "sources", ["memory", "knowledge", "code", "library"])
    max_tokens = Map.get(args, "max_tokens", 2000)

    # Run parallel queries
    tasks = build_tasks(query, entities, sources)

    # Collect results with timeout
    results =
      tasks
      |> Enum.map(fn {_name, task} -> task end)
      |> Task.yield_many(10_000)
      |> Enum.zip(tasks)
      |> Enum.map(fn
        {{_task, {:ok, {key, value}}}, _} ->
          {key, value}

        {{task, nil}, {name, _}} ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("[PrepareContext] #{name} task timed out")
          {name, %{error: "timeout", items: []}}

        {{_task, {:exit, reason}}, {name, _}} ->
          Logger.warning("[PrepareContext] #{name} task crashed: #{inspect(reason)}")
          {name, %{error: inspect(reason), items: []}}
      end)
      |> Enum.into(%{})

    duration = System.monotonic_time(:millisecond) - start_time

    # Build structured response
    build_response(query, entities, results, duration, max_tokens, args)
  end

  defp build_tasks(query, entities, sources) do
    # Core context sources
    all_tasks = [
      {"memory",
       TaskHelper.async_with_callers(fn -> {:memory, gather_memories(query, entities)} end)},
      {"knowledge",
       TaskHelper.async_with_callers(fn -> {:knowledge, gather_knowledge(query, entities)} end)},
      {"code", TaskHelper.async_with_callers(fn -> {:code, gather_code_context(entities)} end)},
      {"library",
       TaskHelper.async_with_callers(fn -> {:library, gather_library_context(entities)} end)},
      # DEMAND 3: Pattern matching - find relevant emergence patterns
      {"patterns", TaskHelper.async_with_callers(fn -> {:patterns, gather_patterns(query)} end)},
      # DEMAND 5: Wisdom injection - gather failures and lessons
      {"wisdom", TaskHelper.async_with_callers(fn -> {:wisdom, gather_wisdom(query)} end)},
      # Phase 3: Cross-domain knowledge transfer
      {"cross_domain",
       TaskHelper.async_with_callers(fn -> {:cross_domain, gather_cross_domain(query)} end)}
    ]

    # Filter to only requested sources (patterns, wisdom, cross_domain always included for cognitive boost)
    standard_sources =
      Enum.filter(all_tasks, fn {name, _task} ->
        name in sources or name in ["patterns", "wisdom", "cross_domain"]
      end)

    standard_sources
  end

  # ==========================================================================
  # DEMAND 3: PATTERN LIBRARY MATCHING
  # ==========================================================================

  defp gather_patterns(query) do
    # Search for relevant emergence patterns that match this query
    case Mimo.Brain.Emergence.Pattern.search_by_description(query, limit: 5) do
      patterns when is_list(patterns) and length(patterns) > 0 ->
        formatted_patterns =
          Enum.map(patterns, fn p ->
            %{
              id: p.id,
              type: p.type,
              description: p.description,
              success_rate: Float.round((p.success_rate || 0) * 100, 1),
              occurrences: p.occurrences,
              recommendation: pattern_recommendation(p)
            }
          end)

        %{
          count: length(formatted_patterns),
          items: formatted_patterns,
          matched: true
        }

      _ ->
        %{count: 0, items: [], matched: false}
    end
  rescue
    e ->
      Logger.debug("[PrepareContext] Pattern search failed: #{Exception.message(e)}")
      %{count: 0, items: [], matched: false, error: Exception.message(e)}
  end

  defp pattern_recommendation(pattern) do
    case pattern.type do
      :workflow ->
        "Follow this proven workflow (#{pattern.occurrences}x successful)"

      :heuristic ->
        "Apply this rule of thumb (#{Float.round((pattern.success_rate || 0) * 100, 1)}% success)"

      :inference ->
        "Consider this pattern-based conclusion"

      :skill ->
        "Use this established skill approach"

      _ ->
        "Review this relevant pattern"
    end
  end

  # ==========================================================================
  # DEMAND 5: WISDOM INJECTION
  # ==========================================================================

  defp gather_wisdom(query) do
    # Use WisdomInjector to gather failures, warnings, and lessons
    case Mimo.Brain.WisdomInjector.gather_wisdom(query, 0.5) do
      wisdom when is_map(wisdom) ->
        %{
          failures: wisdom[:failures] || [],
          warnings: wisdom[:warnings] || [],
          formatted: wisdom[:formatted] || "",
          count: length(wisdom[:failures] || []) + length(wisdom[:warnings] || [])
        }

      _ ->
        %{failures: [], warnings: [], formatted: "", count: 0}
    end
  rescue
    e ->
      Logger.debug("[PrepareContext] Wisdom gathering failed: #{Exception.message(e)}")
      %{failures: [], warnings: [], formatted: "", count: 0, error: Exception.message(e)}
  end

  # ==========================================================================
  # PHASE 3: CROSS-DOMAIN KNOWLEDGE TRANSFER
  # ==========================================================================

  defp gather_cross_domain(query) do
    # Find cross-domain insights that might help with the current task
    case KnowledgeTransfer.find_transfers(query, limit: 3) do
      {:ok, transfers} when is_list(transfers) and length(transfers) > 0 ->
        formatted_transfers =
          Enum.map(transfers, fn t ->
            %{
              from: t.source_domain,
              to: t.target_domain,
              concept: t.concept,
              insight: "From #{t.source_domain}: #{t.source_pattern}",
              recommendation: "In #{t.target_domain}: #{t.target_pattern}",
              confidence: Float.round(t.confidence, 2)
            }
          end)

        %{
          count: length(formatted_transfers),
          items: formatted_transfers,
          target_domain: if(length(transfers) > 0, do: hd(transfers).target_domain, else: :unknown)
        }

      _ ->
        %{count: 0, items: [], target_domain: :unknown}
    end
  rescue
    e ->
      Logger.debug("[PrepareContext] Cross-domain transfer failed: #{Exception.message(e)}")
      %{count: 0, items: [], error: Exception.message(e)}
  end

  # ==========================================================================
  # SOURCE GATHERERS
  # ==========================================================================

  defp gather_memories(query, entities) do
    # Search for relevant memories using the query and entities
    search_terms = [query | entities] |> Enum.take(3)

    results =
      search_terms
      |> Enum.flat_map(fn term ->
        case Memory.search_memories(term, limit: 5, min_similarity: 0.35) do
          memories when is_list(memories) ->
            Enum.map(memories, fn mem ->
              %{
                content: Map.get(mem, :content) || Map.get(mem, "content"),
                category: Map.get(mem, :category) || Map.get(mem, "category"),
                importance: Map.get(mem, :importance) || Map.get(mem, "importance") || 0.5,
                score: Map.get(mem, :similarity) || Map.get(mem, :score) || 0.5
              }
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(& &1.content)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(10)

    %{
      count: length(results),
      items: results
    }
  end

  defp gather_knowledge(query, entities) do
    # Query knowledge graph for relationships
    results =
      case Knowledge.dispatch(%{"operation" => "query", "query" => query, "limit" => 10}) do
        {:ok, result} ->
          semantic = result[:semantic_store] || %{}
          synapse = result[:synapse_graph] || %{}

          relationships = extract_relationships(semantic)
          nodes = synapse[:nodes] || []

          %{
            relationships: relationships,
            nodes: Enum.take(nodes, 5),
            count: length(relationships) + length(nodes)
          }

        {:error, _} ->
          %{relationships: [], nodes: [], count: 0}
      end

    # Also try entity-specific queries
    entity_results =
      entities
      |> Enum.take(3)
      |> Enum.flat_map(fn entity ->
        case Knowledge.dispatch(%{
               "operation" => "query",
               "query" => entity,
               "limit" => 5
             }) do
          {:ok, result} ->
            extract_relationships(result[:semantic_store] || %{})

          _ ->
            []
        end
      end)
      |> Enum.uniq()
      |> Enum.take(10)

    %{
      count: results.count + length(entity_results),
      relationships: (results.relationships ++ entity_results) |> Enum.uniq() |> Enum.take(15),
      nodes: results.nodes
    }
  end

  defp gather_code_context(entities) do
    # Search for code symbols matching entities
    results =
      entities
      |> Enum.take(5)
      |> Enum.flat_map(fn entity ->
        # Try definition lookup
        # Try symbol search
        case Code.dispatch(%{"operation" => "definition", "name" => entity}) do
          {:ok, %{found: true} = result} ->
            [
              %{
                type: :definition,
                symbol: entity,
                file: result[:file_path] || result[:definition][:file_path],
                line: result[:line] || result[:definition][:start_line]
              }
            ]

          _ ->
            []
        end ++
          case Code.dispatch(%{"operation" => "search", "pattern" => "*#{entity}*", "limit" => 3}) do
            {:ok, %{symbols: symbols}} when is_list(symbols) ->
              Enum.map(symbols, fn sym ->
                %{
                  type: :symbol,
                  symbol: sym[:name] || sym["name"],
                  kind: sym[:kind] || sym["kind"],
                  file: sym[:file_path] || sym["file_path"],
                  line: sym[:start_line] || sym["start_line"]
                }
              end)

            _ ->
              []
          end
      end)
      |> Enum.uniq_by(&{&1.symbol, &1.file})
      |> Enum.take(10)

    %{
      count: length(results),
      items: results
    }
  end

  defp gather_library_context(entities) do
    # Look up relevant package documentation
    # Try to identify package names from entities
    package_candidates =
      entities
      |> Enum.filter(&potential_package_name?/1)
      |> Enum.take(3)

    results =
      package_candidates
      |> Enum.flat_map(fn pkg ->
        # Try different ecosystems
        Enum.flat_map(["hex", "npm", "pypi"], fn ecosystem ->
          case Library.dispatch(%{
                 "operation" => "get",
                 "name" => String.downcase(pkg),
                 "ecosystem" => ecosystem
               }) do
            {:ok, %{found: true} = result} ->
              [
                %{
                  package: pkg,
                  ecosystem: ecosystem,
                  version: result[:version],
                  description: result[:description] |> truncate(200)
                }
              ]

            _ ->
              []
          end
        end)
      end)
      |> Enum.take(5)

    %{
      count: length(results),
      items: results
    }
  end

  # ==========================================================================
  # RESPONSE BUILDING
  # ==========================================================================

  defp build_response(query, entities, results, duration, max_tokens, args) do
    memory = results[:memory] || %{items: [], count: 0}
    knowledge = results[:knowledge] || %{relationships: [], nodes: [], count: 0}
    code = results[:code] || %{items: [], count: 0}
    library = results[:library] || %{items: [], count: 0}
    # DEMAND 3 & 5: Pattern library and wisdom injection
    patterns = results[:patterns] || %{items: [], count: 0}
    wisdom = results[:wisdom] || %{failures: [], warnings: [], count: 0}

    include_scores = Map.get(args, "include_scores", false)
    tiered = Map.get(args, "tiered", false)

    # SPEC-051: Build tiered response if requested
    if tiered do
      build_tiered_response(query, entities, results, duration, max_tokens, args)
    else
      # Legacy flat response for backward compatibility
      build_flat_response(
        query,
        entities,
        memory,
        knowledge,
        code,
        library,
        patterns,
        wisdom,
        duration,
        max_tokens,
        include_scores
      )
    end
  end

  # SPEC-051: Tiered response building
  defp build_tiered_response(query, entities, results, duration, max_tokens, args) do
    model_type = Map.get(args, "model_type", "medium")
    include_tier3 = Map.get(args, "include_tier3", false)
    include_scores = Map.get(args, "include_scores", false)

    # Get budget allocation
    budget = BudgetAllocator.allocate(model_type, max_tokens)

    # Collect all items with their source type
    all_items = collect_all_items(results)

    # Classify items into tiers using HybridScorer
    classified =
      HybridScorer.classify_items(all_items, nil,
        model_type: BudgetAllocator.model_type(model_type)
      )

    # Apply budget constraints to each tier
    {tier1_items, tier1_remaining} = BudgetAllocator.fit_to_budget(classified.tier1, budget.tier1)
    {tier2_items, tier2_remaining} = BudgetAllocator.fit_to_budget(classified.tier2, budget.tier2)

    tier3_items =
      if include_tier3 do
        {items, _} = BudgetAllocator.fit_to_budget(classified.tier3, budget.tier3)
        items
      else
        []
      end

    # Calculate token usage
    tier1_tokens = budget.tier1 - tier1_remaining
    tier2_tokens = budget.tier2 - tier2_remaining

    tier3_tokens =
      if include_tier3,
        do: Enum.reduce(tier3_items, 0, &(BudgetAllocator.estimate_item_tokens(&1) + &2)),
        else: 0

    # Format each tier
    tier1_formatted = format_tier_items(tier1_items, include_scores)
    tier2_formatted = format_tier_items(tier2_items, include_scores)

    tier3_formatted =
      if include_tier3, do: format_tier_items(tier3_items, include_scores), else: nil

    {:ok,
     %{
       query: query,
       entities_extracted: entities,
       duration_ms: duration,
       tiered: true,
       model_type: model_type,
       context: %{
         tier1: tier1_formatted,
         tier2: tier2_formatted,
         tier3:
           if(include_tier3,
             do: tier3_formatted,
             else: %{
               available: length(classified.tier3) > 0,
               estimated_tokens:
                 Enum.reduce(classified.tier3, 0, &(BudgetAllocator.estimate_item_tokens(&1) + &2)),
               items_count: length(classified.tier3)
             }
           )
       },
       metadata: %{
         token_usage: %{
           tier1: tier1_tokens,
           tier2: tier2_tokens,
           tier3: tier3_tokens,
           total: tier1_tokens + tier2_tokens + tier3_tokens,
           budget: budget
         },
         items_per_tier: %{
           tier1: length(tier1_items),
           tier2: length(tier2_items),
           tier3: length(tier3_items)
         },
         predictive_suggestions: build_predictive_suggestions(entities, results)
       },
       suggestion: build_tiered_suggestion(tier1_items, tier2_items, classified.tier3, model_type)
     }}
  end

  # Legacy flat response format
  defp build_flat_response(
         query,
         entities,
         memory,
         knowledge,
         code,
         library,
         patterns,
         wisdom,
         duration,
         max_tokens,
         include_scores
       ) do
    # Build structured context with patterns and wisdom
    context_sections =
      build_context_sections(memory, knowledge, code, library, patterns, wisdom, include_scores)

    # Calculate totals (include patterns and wisdom)
    total_items =
      (memory[:count] || 0) + (knowledge[:count] || 0) + (code[:count] || 0) +
        (library[:count] || 0) + (patterns[:count] || 0) + (wisdom[:count] || 0)

    # Build formatted context string with token-aware truncation
    formatted_context = format_context_string(context_sections, max_tokens)

    {:ok,
     %{
       query: query,
       entities_extracted: entities,
       duration_ms: duration,
       total_context_items: total_items,
       max_tokens: max_tokens,
       context: %{
         memory: memory,
         knowledge: knowledge,
         code: code,
         library: library,
         patterns: patterns,
         wisdom: wisdom
       },
       formatted_context: formatted_context,
       sections: context_sections,
       # Enhanced suggestion with pattern/wisdom status
       suggestion: build_suggestion(total_items, memory, knowledge, code, patterns, wisdom),
       # Small model boost indicators
       small_model_boost: %{
         patterns_matched: (patterns[:count] || 0) > 0,
         wisdom_injected: (wisdom[:count] || 0) > 0,
         has_failures_to_avoid: length(wisdom[:failures] || []) > 0,
         has_warnings: length(wisdom[:warnings] || []) > 0
       }
     }}
  end

  # ==========================================================================
  # SPEC-051: Tiered Context Helpers
  # ==========================================================================

  defp collect_all_items(results) do
    memory_items =
      (results[:memory][:items] || [])
      |> Enum.map(&Map.put(&1, :source_type, :memory))

    code_items =
      (results[:code][:items] || [])
      |> Enum.map(&Map.put(&1, :source_type, :code))

    library_items =
      (results[:library][:items] || [])
      |> Enum.map(&Map.put(&1, :source_type, :library))

    pattern_items =
      (results[:patterns][:items] || [])
      |> Enum.map(&Map.put(&1, :source_type, :pattern))

    wisdom_failures =
      (results[:wisdom][:failures] || [])
      |> Enum.map(&Map.put(&1, :source_type, :wisdom_failure))
      # High importance for failures
      |> Enum.map(&Map.put(&1, :importance, 0.95))

    wisdom_warnings =
      (results[:wisdom][:warnings] || [])
      |> Enum.map(&Map.put(&1, :source_type, :wisdom_warning))
      # High importance for warnings
      |> Enum.map(&Map.put(&1, :importance, 0.85))

    # Knowledge items (relationships and nodes)
    knowledge_rels =
      (results[:knowledge][:relationships] || [])
      |> Enum.map(fn rel ->
        %{content: rel, source_type: :knowledge_relationship, importance: 0.6}
      end)

    knowledge_nodes =
      (results[:knowledge][:nodes] || [])
      |> Enum.map(&Map.put(&1, :source_type, :knowledge_node))

    # Combine all items
    memory_items ++
      code_items ++
      library_items ++
      pattern_items ++
      wisdom_failures ++ wisdom_warnings ++ knowledge_rels ++ knowledge_nodes
  end

  defp format_tier_items(items, include_scores) do
    Enum.map(items, fn item ->
      base = %{
        type: item[:source_type] || :unknown,
        content: format_item_content(item)
      }

      base =
        if item[:file],
          do: Map.put(base, :source, "#{item[:file]}:#{item[:line] || "?"}"),
          else: base

      base =
        if item[:urs] && include_scores,
          do: Map.put(base, :relevance, Float.round(item[:urs], 3)),
          else: base

      # Add cross-modality info if available
      if cross_refs = item[:cross_modality] || item[:cross_modality_connections] do
        Map.put(base, :cross_modality, cross_refs)
      else
        base
      end
    end)
  end

  defp format_item_content(item) do
    cond do
      item[:content] ->
        item[:content]

      item[:description] ->
        item[:description]

      item[:symbol] ->
        "#{item[:kind] || "symbol"}: #{item[:symbol]}"

      item[:package] ->
        "#{item[:package]} (#{item[:ecosystem]}): #{item[:description] || "no description"}"

      item[:lesson] ->
        "⚠️ #{item[:lesson]}"

      item[:message] ->
        item[:message]

      true ->
        inspect(item)
    end
  end

  defp build_predictive_suggestions(entities, _results) do
    # Simple predictive suggestions based on entities
    # Future: Use ML model or pattern matching for better predictions
    entities
    |> Enum.take(3)
    |> Enum.flat_map(fn entity ->
      cond do
        String.ends_with?(entity, ".ex") or String.ends_with?(entity, ".exs") ->
          [entity, String.replace(entity, ".ex", "_test.exs")]

        String.contains?(entity, "_") ->
          # Snake case suggests a function - suggest related test
          ["test/#{entity}_test.exs"]

        String.match?(entity, ~r/^[A-Z]/) ->
          # CamelCase suggests a module
          ["lib/#{Macro.underscore(entity)}.ex"]

        true ->
          []
      end
    end)
    |> Enum.take(5)
  end

  defp build_tiered_suggestion(tier1, tier2, tier3, model_type) do
    tier1_count = length(tier1)
    tier2_count = length(tier2)
    tier3_count = length(tier3)
    total = tier1_count + tier2_count + tier3_count

    cond do
      total == 0 ->
        "💡 No context found. Consider running `onboard` to index the codebase first."

      tier1_count == 0 and tier2_count == 0 ->
        "💡 Only background context available. Results may be less precise."

      tier1_count > 0 and tier3_count > 10 ->
        "✨ #{tier1_count} essential + #{tier2_count} supporting items. #{tier3_count} more available in Tier 3 if needed."

      true ->
        model_name = if is_binary(model_type), do: model_type, else: Atom.to_string(model_type)

        "🎯 Tiered context for #{model_name}: #{tier1_count} essential, #{tier2_count} supporting items loaded."
    end
  end

  defp build_context_sections(memory, knowledge, code, library, patterns, wisdom, include_scores) do
    [
      # DEMAND 5: Wisdom/warnings first (most important for small models)
      build_wisdom_section(wisdom),
      # DEMAND 3: Pattern matches second
      build_patterns_section(patterns),
      # Standard context
      build_memory_section(memory, include_scores),
      build_knowledge_section(knowledge),
      build_code_section(code),
      build_library_section(library)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # DEMAND 3: Pattern Library Section
  defp build_patterns_section(%{count: count, items: items}) when count > 0 do
    formatted_items =
      Enum.map(items, fn p ->
        "• [#{p.type}] #{p.description} — #{p.recommendation} (#{p.success_rate}% success, #{p.occurrences}x seen)"
      end)

    %{name: "📚 Matching Patterns (from past sessions)", items: formatted_items}
  end

  defp build_patterns_section(_), do: nil

  # DEMAND 5: Wisdom Injection Section
  defp build_wisdom_section(%{count: count} = wisdom) when count > 0 do
    items = []

    # Add failures
    items =
      items ++
        Enum.map(wisdom[:failures] || [], fn f ->
          "⚠️ PAST FAILURE: #{f.lesson} — #{String.slice(f.content || "", 0, 100)}"
        end)

    # Add warnings
    items =
      items ++
        Enum.map(wisdom[:warnings] || [], fn w ->
          "#{w.message}"
        end)

    if length(items) > 0 do
      %{name: "🚨 Wisdom Injection (avoid these mistakes)", items: items}
    else
      nil
    end
  end

  defp build_wisdom_section(_), do: nil

  defp build_memory_section(%{count: count, items: items}, include_scores) when count > 0 do
    formatted_items =
      Enum.map(items, fn item ->
        base = "• [#{item.category || "memory"}] #{item.content}"

        if include_scores do
          "#{base} (relevance: #{Float.round((item.score || 0.5) * 100, 1)}%)"
        else
          base
        end
      end)

    %{name: "Relevant Memories", items: formatted_items}
  end

  defp build_memory_section(_, _), do: nil

  defp build_knowledge_section(%{count: count} = knowledge) when count > 0 do
    rel_items = Enum.map(knowledge[:relationships] || [], &"• #{&1}")

    node_items =
      Enum.map(knowledge[:nodes] || [], fn node ->
        "• [#{node[:type] || "node"}] #{node[:name] || node[:id]}"
      end)

    %{name: "Knowledge Graph", items: rel_items ++ node_items}
  end

  defp build_knowledge_section(_), do: nil

  defp build_code_section(%{count: count, items: items}) when count > 0 do
    formatted_items =
      Enum.map(items, fn item ->
        location =
          if Map.get(item, :file),
            do: " (#{Path.basename(Map.get(item, :file, ""))}:#{Map.get(item, :line, "?")})",
            else: ""

        kind = Map.get(item, :kind) || Map.get(item, :type, "unknown")
        symbol = Map.get(item, :symbol, "?")
        "• [#{kind}] #{symbol}#{location}"
      end)

    %{name: "Code Context", items: formatted_items}
  end

  defp build_code_section(_), do: nil

  defp build_library_section(%{count: count, items: items}) when count > 0 do
    formatted_items =
      Enum.map(items, fn item ->
        "• #{item.package} (#{item.ecosystem}): #{item.description || "no description"}"
      end)

    %{name: "Related Packages", items: formatted_items}
  end

  defp build_library_section(_), do: nil

  # Token-aware context formatting
  # Roughly estimate 4 characters per token
  @chars_per_token 4

  defp format_context_string(sections, max_tokens) do
    max_chars = max_tokens * @chars_per_token

    # Build all sections first
    all_content =
      Enum.map_join(sections, "\n\n", fn section ->
        header = "## #{section.name}\n"
        items = Enum.join(section.items, "\n")
        header <> items
      end)

    # Truncate if needed
    if String.length(all_content) > max_chars do
      truncate_context(all_content, max_chars)
    else
      all_content
    end
  end

  defp truncate_context(content, max_chars) do
    truncated = String.slice(content, 0, max_chars - 60)
    omitted_chars = String.length(content) - String.length(truncated)
    omitted_tokens = div(omitted_chars, @chars_per_token)
    truncated <> "\n\n... [CONTEXT TRUNCATED - ~#{omitted_tokens} tokens omitted for budget]"
  end

  # Enhanced suggestion with pattern/wisdom status
  defp build_suggestion(total_items, memory, knowledge, code, patterns, wisdom) do
    cond do
      total_items == 0 ->
        "💡 No context found. Consider running `onboard` to index the codebase first."

      has_wisdom?(wisdom) ->
        build_wisdom_suggestion(wisdom)

      has_patterns?(patterns) ->
        "📚 #{patterns[:count]} matching patterns found from past sessions. Review for guidance."

      missing_memory?(memory, total_items) ->
        "💡 No memory context found. Store insights in memory as you learn."

      missing_code?(code, total_items) ->
        "💡 No code context found. Index code/relationships first (onboard or knowledge link)."

      missing_knowledge?(knowledge, total_items) ->
        "💡 Knowledge graph is sparse. Teach key relationships so future queries improve."

      true ->
        "✨ Rich context loaded! #{total_items} relevant items found."
    end
  end

  defp has_wisdom?(wisdom), do: (wisdom[:count] || 0) > 0
  defp has_patterns?(patterns), do: (patterns[:count] || 0) > 0
  defp missing_memory?(memory, total), do: (memory[:count] || 0) == 0 and total > 0
  defp missing_code?(code, total), do: (code[:count] || 0) == 0 and total > 0
  defp missing_knowledge?(knowledge, total), do: (knowledge[:count] || 0) == 0 and total > 0

  defp build_wisdom_suggestion(wisdom) do
    failure_count = length(wisdom[:failures] || [])
    warning_count = length(wisdom[:warnings] || [])

    "🧠 WISDOM INJECTED: #{failure_count} past failures to avoid, #{warning_count} warnings. Read carefully!"
  end

  # ==========================================================================
  # ENTITY EXTRACTION
  # ==========================================================================

  defp extract_entities(query) do
    # Extract potential entities from the query
    # This is a simple heuristic-based extraction

    # 1. CamelCase words (likely class/module names)
    camel_case =
      Regex.scan(~r/\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b/, query)
      |> Enum.map(fn [_, match] -> match end)

    # 2. snake_case words (likely function/variable names)
    snake_case =
      Regex.scan(~r/\b([a-z]+(?:_[a-z]+)+)\b/, query)
      |> Enum.map(fn [_, match] -> match end)

    # 3. Quoted strings
    quoted =
      Regex.scan(~r/["`']([^"`']+)["`']/, query)
      |> Enum.map(fn [_, match] -> match end)

    # 4. File paths
    paths =
      Regex.scan(~r/\b([\w\/]+\.(?:ex|exs|ts|tsx|js|jsx|py|rs|go))\b/, query)
      |> Enum.map(fn [_, match] -> match end)

    # 5. Significant words (nouns, likely concepts) - simple heuristic
    words =
      query
      |> String.downcase()
      |> String.split(~r/\s+/)
      |> Enum.filter(fn word ->
        String.length(word) > 4 and
          word not in ~w(about which where there their would could should these those)
      end)
      |> Enum.take(5)

    # Combine and deduplicate
    (camel_case ++ snake_case ++ quoted ++ paths ++ words)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  # ==========================================================================
  # HELPERS
  defp extract_relationships(semantic_store) when is_map(semantic_store) do
    relationships_map = get_map_value(semantic_store, [:relationships, "relationships"], %{})
    outgoing = get_map_value(relationships_map, [:outgoing, "outgoing"], [])
    incoming = get_map_value(relationships_map, [:incoming, "incoming"], [])

    (outgoing ++ incoming)
    |> Enum.map(&format_relationship/1)
    |> Enum.uniq()
  end

  defp extract_relationships(_), do: []

  defp format_relationship(rel) do
    subject = get_map_value(rel, [:subject, "subject", :subject_id, "subject_id"], "?")
    predicate = get_map_value(rel, [:predicate, "predicate", :pred, "pred"], "relates_to")
    object = get_map_value(rel, [:object, "object", :object_id, "object_id"], "?")
    "#{subject} #{predicate} #{object}"
  end

  defp get_map_value(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key -> Map.get(map, key) end) || default
  end

  defp get_map_value(_, _, default), do: default

  @doc false
  def extract_relationships_for_test(semantic_store), do: extract_relationships(semantic_store)

  defp potential_package_name?(entity) do
    # Simple heuristic: lowercase, no spaces, reasonable length
    String.match?(entity, ~r/^[a-z][a-z0-9_-]*$/) and
      String.length(entity) >= 2 and
      String.length(entity) <= 50
  end

  defp truncate(nil, _max), do: nil
  defp truncate(str, max) when is_binary(str) and byte_size(str) <= max, do: str
  defp truncate(str, max) when is_binary(str), do: String.slice(str, 0, max) <> "..."
  defp truncate(other, _max), do: inspect(other)
end
