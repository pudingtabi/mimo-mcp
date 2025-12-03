defmodule Mimo.Tools.Dispatchers.PrepareContext do
  @moduledoc """
  Compound cognitive tool: Smart Context Preparation.

  SPEC-036: Aggregates context from multiple Mimo cognitive systems in parallel
  to give any model (especially small ones) a "photographic memory" of the project.

  This is the FOUNDATION for small model capability enhancement. By providing
  rich, relevant context BEFORE the model starts reasoning, we compensate for
  limited context windows and parametric knowledge.

  Pipeline:
  1. Parse query to extract key entities/concepts
  2. Parallel gather from: memory, knowledge, code_symbols, library, recent actions
  3. Rank and filter by relevance
  4. Return structured context for injection into model's working memory

  This tool embodies the principle: "Context is Power"
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.{Code, Knowledge, Library}
  alias Mimo.TaskHelper

  @doc """
  Dispatch prepare_context operation.

  ## Options
    - query: The task/query to gather context for (required)
    - max_tokens: Approximate max tokens for output (default: 2000)
    - sources: List of sources to query (default: all)
               Options: ["memory", "knowledge", "code", "library", "actions"]
    - include_scores: Include relevance scores in output (default: false)
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
    all_tasks = [
      {"memory",
       TaskHelper.async_with_callers(fn -> {:memory, gather_memories(query, entities)} end)},
      {"knowledge",
       TaskHelper.async_with_callers(fn -> {:knowledge, gather_knowledge(query, entities)} end)},
      {"code", TaskHelper.async_with_callers(fn -> {:code, gather_code_context(entities)} end)},
      {"library",
       TaskHelper.async_with_callers(fn -> {:library, gather_library_context(entities)} end)}
    ]

    # Filter to only requested sources
    Enum.filter(all_tasks, fn {name, _task} -> name in sources end)
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

    include_scores = Map.get(args, "include_scores", false)

    # Build structured context
    context_sections = build_context_sections(memory, knowledge, code, library, include_scores)

    # Calculate totals
    total_items =
      (memory[:count] || 0) + (knowledge[:count] || 0) + (code[:count] || 0) +
        (library[:count] || 0)

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
         library: library
       },
       formatted_context: formatted_context,
       sections: context_sections,
       suggestion: build_suggestion(total_items, memory, knowledge, code)
     }}
  end

  defp build_context_sections(memory, knowledge, code, library, include_scores) do
    [
      build_memory_section(memory, include_scores),
      build_knowledge_section(knowledge),
      build_code_section(code),
      build_library_section(library)
    ]
    |> Enum.reject(&is_nil/1)
  end

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

  defp build_suggestion(total_items, memory, knowledge, code) do
    cond do
      total_items == 0 ->
        "💡 No context found. Consider running `onboard` to index the codebase first."

      (memory[:count] || 0) == 0 and total_items > 0 ->
        "💡 No memory context found. Store insights with `memory operation=store` as you learn."

      (code[:count] || 0) == 0 and total_items > 0 ->
        "💡 No code context found. Run `knowledge operation=link path=\".\"` to index code."

      (knowledge[:count] || 0) == 0 and total_items > 0 ->
        "💡 Knowledge graph is sparse. Use `knowledge operation=teach` to add relationships."

      true ->
        "✨ Rich context loaded! #{total_items} relevant items found."
    end
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
  # ==========================================================================

  defp extract_relationships(semantic_store) when is_map(semantic_store) do
    outgoing = semantic_store[:relationships][:outgoing] || []
    incoming = semantic_store[:relationships][:incoming] || []

    (outgoing ++ incoming)
    |> Enum.map(fn rel ->
      subject = rel[:subject] || rel["subject"] || "?"
      predicate = rel[:predicate] || rel["predicate"] || "relates_to"
      object = rel[:object] || rel["object"] || "?"
      "#{subject} #{predicate} #{object}"
    end)
    |> Enum.uniq()
  end

  defp extract_relationships(_), do: []

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
