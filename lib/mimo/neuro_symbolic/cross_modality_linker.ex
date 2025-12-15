defmodule Mimo.NeuroSymbolic.CrossModalityLinker do
  @moduledoc """
  SPEC-051 Phase 2: Cross-modality linking utilities.

  Provides functions for inferring and managing links between:
  - Code symbols (functions, modules, classes)
  - Memories (episodic, working)
  - Knowledge nodes (concepts, relationships)
  - Library packages (documentation)

  Cross-modality connections boost relevance scores in the tiered context system.
  """
  alias Mimo.Repo
  alias Mimo.Synapse.{GraphNode, GraphEdge}
  import Ecto.Query
  require Logger

  @type source_type :: :code_symbol | :memory | :knowledge | :library
  @type link_result :: {:ok, [map()]} | {:error, term()}

  @doc """
  Infer links from a specific source to other modalities.

  ## Parameters

    * `source_type` - Type of source (:code_symbol, :memory, :knowledge, :library)
    * `source_id` - Identifier for the source
    * `opts` - Options:
      * `:limit` - Max links to return (default: 10)
      * `:min_confidence` - Minimum confidence threshold (default: 0.5)

  ## Returns

    {:ok, [link_map]} or {:error, reason}
  """
  @spec infer_links(source_type(), String.t(), keyword()) :: link_result()
  def infer_links(source_type, source_id, opts \\ [])

  def infer_links(:code_symbol, symbol_id, opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # Find memories that mention this symbol
    memory_links = infer_memory_links_for_symbol(symbol_id, limit)

    # Find library packages used by this symbol
    library_links = infer_library_links_for_symbol(symbol_id, limit)

    # Find knowledge nodes related to this symbol
    knowledge_links = infer_knowledge_links_for_symbol(symbol_id, limit)

    all_links =
      (memory_links ++ library_links ++ knowledge_links)
      |> Enum.filter(&(&1.confidence >= min_confidence))
      |> Enum.take(limit)

    {:ok, all_links}
  rescue
    e ->
      Logger.error("infer_links/3 failed for code_symbol #{symbol_id}: #{inspect(e)}")
      {:error, e}
  end

  def infer_links(:memory, memory_id, opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # Find code symbols mentioned in this memory
    code_links = infer_code_links_for_memory(memory_id, limit)

    # Find knowledge nodes related to this memory
    knowledge_links = infer_knowledge_links_for_memory(memory_id, limit)

    all_links =
      (code_links ++ knowledge_links)
      |> Enum.filter(&(&1.confidence >= min_confidence))
      |> Enum.take(limit)

    {:ok, all_links}
  rescue
    e ->
      Logger.error("infer_links/3 failed for memory #{memory_id}: #{inspect(e)}")
      {:error, e}
  end

  def infer_links(:knowledge, node_id, opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # Find connected entities via graph traversal
    links = infer_connected_entities(node_id, limit)

    filtered_links =
      links
      |> Enum.filter(&(&1.confidence >= min_confidence))
      |> Enum.take(limit)

    {:ok, filtered_links}
  rescue
    e ->
      Logger.error("infer_links/3 failed for knowledge #{node_id}: #{inspect(e)}")
      {:error, e}
  end

  def infer_links(:library, package_name, opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)

    # Find code that imports/uses this library
    code_links = infer_code_links_for_library(package_name, limit)

    filtered_links =
      code_links
      |> Enum.filter(&(&1.confidence >= min_confidence))
      |> Enum.take(limit)

    {:ok, filtered_links}
  rescue
    e ->
      Logger.error("infer_links/3 failed for library #{package_name}: #{inspect(e)}")
      {:error, e}
  end

  # Fallback for unknown source types
  def infer_links(unknown_type, _source_id, _opts) do
    Logger.debug("infer_links called with unknown source type: #{inspect(unknown_type)}")
    {:ok, []}
  end

  @doc """
  Find cross-source connections for an item.

  Returns the number of unique sources this item is connected to,
  which is used to calculate the cross-modality score in HybridScorer.

  ## Parameters

    * `item` - Item map with :source_type and :id fields
    * `opts` - Options for connection lookup

  ## Returns

    Integer count of connected source types (0, 1, or 2+)
  """
  @spec find_cross_connections(map(), keyword()) :: non_neg_integer()
  def find_cross_connections(item, opts \\ []) do
    source_type = item[:source_type] || infer_source_type(item)
    source_id = item[:id] || item["id"]

    if is_nil(source_id) do
      # Check for inline cross-modality markers
      count_inline_connections(item)
    else
      case infer_links(source_type, to_string(source_id), opts) do
        {:ok, links} ->
          # Count unique target types
          links
          |> Enum.map(& &1.target_type)
          |> Enum.uniq()
          |> length()

        {:error, _} ->
          count_inline_connections(item)
      end
    end
  end

  @doc """
  Batch infer links for multiple source pairs.

  ## Parameters

    * `pairs` - List of {source_type, source_id} tuples

  ## Returns

    {:ok, [link_map]} with all discovered links
  """
  @spec link_all([{source_type(), String.t()}]) :: link_result()
  def link_all(pairs, opts \\ []) when is_list(pairs) do
    persist = Keyword.get(opts, :persist, false)

    links =
      pairs
      |> Enum.flat_map(fn {type, id} ->
        case infer_links(type, id) do
          {:ok, links} -> links
          _ -> []
        end
      end)

    if persist and links != [] do
      entries =
        links
        |> Enum.map(fn link ->
          %{
            source_type: to_string(link.source_type),
            source_id: to_string(link.source_id),
            target_type: to_string(link.target_type),
            target_id: to_string(link.target_id),
            link_type: to_string(link.link_type),
            confidence: link.confidence || 0.5,
            discovered_by: link.discovered_by || "inference",
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond),
            updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
          }
        end)

      {count, _} =
        Repo.insert_all(Mimo.NeuroSymbolic.CrossModalityLink, entries, on_conflict: :nothing)

      Logger.info("Persisted #{count} cross-modality links")
    end

    {:ok, links}
  end

  @doc """
  Get cross-modality statistics for an entity.

  ## Returns

    Map with connection counts and types
  """
  @spec cross_modality_stats(source_type(), String.t()) :: map()
  def cross_modality_stats(source_type, source_id) do
    case infer_links(source_type, source_id, limit: 100) do
      {:ok, links} ->
        by_type = Enum.group_by(links, & &1.target_type)

        %{
          total_connections: length(links),
          by_target_type: Map.new(by_type, fn {type, items} -> {type, length(items)} end),
          average_confidence:
            if(links == [],
              do: 0.0,
              else: Enum.sum(Enum.map(links, & &1.confidence)) / length(links)
            ),
          source_type: source_type,
          source_id: source_id
        }

      {:error, _} ->
        %{
          total_connections: 0,
          by_target_type: %{},
          average_confidence: 0.0,
          source_type: source_type,
          source_id: source_id
        }
    end
  end

  # ==========================================================================
  # Private: Memory Link Inference
  # ==========================================================================

  defp infer_memory_links_for_symbol(symbol_id, limit) do
    # Search memories that contain the symbol name
    case Mimo.Brain.Memory.search(symbol_id, limit: limit) do
      {:ok, memories} when is_list(memories) ->
        Enum.map(memories, fn mem ->
          %{
            source_type: "code_symbol",
            source_id: symbol_id,
            target_type: "memory",
            target_id: to_string(Map.get(mem, :id) || Map.get(mem, "id", "unknown")),
            link_type: "memory_to_code",
            confidence: 0.7,
            discovered_by: "text_mention"
          }
        end)

      memories when is_list(memories) ->
        Enum.map(memories, fn mem ->
          %{
            source_type: "code_symbol",
            source_id: symbol_id,
            target_type: "memory",
            target_id: to_string(Map.get(mem, :id) || Map.get(mem, "id", "unknown")),
            link_type: "memory_to_code",
            confidence: 0.7,
            discovered_by: "text_mention"
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp infer_code_links_for_memory(memory_id, _limit) do
    # Look up memory content and extract code references
    case Mimo.Brain.Memory.get_memory(memory_id) do
      {:ok, engram} ->
        content = engram.content || ""
        extract_code_references(content, memory_id)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp extract_code_references(content, memory_id) do
    # Extract potential function/module names from content
    # Pattern: CamelCase words (modules) and snake_case words with parens (functions)
    module_pattern = ~r/\b([A-Z][a-zA-Z0-9]+(?:\.[A-Z][a-zA-Z0-9]+)*)\b/
    function_pattern = ~r/\b([a-z_][a-z0-9_]*)\s*\(/

    modules = Regex.scan(module_pattern, content) |> Enum.map(&List.first/1) |> Enum.uniq()
    functions = Regex.scan(function_pattern, content) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    module_links =
      Enum.map(modules, fn mod ->
        %{
          source_type: "memory",
          source_id: to_string(memory_id),
          target_type: "code_symbol",
          target_id: mod,
          link_type: "memory_to_code",
          confidence: 0.6,
          discovered_by: "text_extraction"
        }
      end)

    function_links =
      Enum.map(functions, fn func ->
        %{
          source_type: "memory",
          source_id: to_string(memory_id),
          target_type: "code_symbol",
          target_id: func,
          link_type: "memory_to_code",
          confidence: 0.5,
          discovered_by: "text_extraction"
        }
      end)

    module_links ++ function_links
  end

  # ==========================================================================
  # Private: Library Link Inference
  # ==========================================================================

  defp infer_library_links_for_symbol(symbol_id, _limit) do
    # Check if this symbol uses any known libraries
    # This would typically involve static analysis of imports
    # For now, use a heuristic based on naming patterns
    library_hints = extract_library_hints(symbol_id)

    Enum.map(library_hints, fn lib ->
      %{
        source_type: "code_symbol",
        source_id: symbol_id,
        target_type: "library",
        target_id: lib,
        link_type: "code_to_library",
        confidence: 0.6,
        discovered_by: "naming_heuristic"
      }
    end)
  end

  defp infer_code_links_for_library(package_name, limit) do
    # Search for code that imports/requires this library
    # Use graph edges with :uses or :imports type
    query =
      from(e in GraphEdge,
        join: target in GraphNode,
        on: e.target_node_id == target.id,
        where: target.name == ^package_name and e.edge_type in [:uses, :imports],
        join: source in GraphNode,
        on: e.source_node_id == source.id,
        select: source,
        limit: ^limit
      )

    nodes = Repo.all(query)

    Enum.map(nodes, fn node ->
      %{
        source_type: "library",
        source_id: package_name,
        target_type: "code_symbol",
        target_id: node.name,
        link_type: "code_to_library",
        confidence: 0.9,
        discovered_by: "graph_edge"
      }
    end)
  rescue
    _ -> []
  end

  defp extract_library_hints(symbol_id) when is_binary(symbol_id) do
    # Extract library name hints from symbol naming
    cond do
      String.contains?(symbol_id, "Phoenix") -> ["phoenix"]
      String.contains?(symbol_id, "Ecto") -> ["ecto"]
      String.contains?(symbol_id, "Plug") -> ["plug"]
      String.contains?(symbol_id, "Jason") -> ["jason"]
      String.contains?(symbol_id, "Tesla") -> ["tesla"]
      true -> []
    end
  end

  # Handle nil or non-string symbol_id gracefully
  defp extract_library_hints(nil), do: []
  defp extract_library_hints(symbol_id), do: extract_library_hints(to_string(symbol_id))

  # ==========================================================================
  # Private: Knowledge Link Inference
  # ==========================================================================

  defp infer_knowledge_links_for_symbol(symbol_id, limit) do
    # Search knowledge graph for nodes mentioning this symbol
    case Mimo.SemanticStore.query_related(symbol_id, limit: limit) do
      {:ok, results} when is_list(results) ->
        Enum.map(results, fn result ->
          %{
            source_type: "code_symbol",
            source_id: symbol_id,
            target_type: "knowledge",
            target_id: to_string(result[:id] || result["id"] || "unknown"),
            link_type: "knowledge_to_code",
            confidence: 0.65,
            discovered_by: "semantic_search"
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp infer_knowledge_links_for_memory(memory_id, limit) do
    # Find knowledge nodes related to this memory's content
    case Mimo.Brain.Memory.get_memory(memory_id) do
      {:ok, engram} ->
        content = engram.content || ""

        case Mimo.SemanticStore.query_related(content, limit: limit) do
          {:ok, results} when is_list(results) ->
            Enum.map(results, fn result ->
              %{
                source_type: "memory",
                source_id: to_string(memory_id),
                target_type: "knowledge",
                target_id: to_string(result[:id] || result["id"] || "unknown"),
                link_type: "memory_to_knowledge",
                confidence: 0.6,
                discovered_by: "semantic_search"
              }
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp infer_connected_entities(node_id, limit) do
    # Traverse graph edges from this knowledge node
    query =
      from(e in GraphEdge,
        where: e.source_node_id == ^node_id or e.target_node_id == ^node_id,
        join: source in GraphNode,
        on: e.source_node_id == source.id,
        join: target in GraphNode,
        on: e.target_node_id == target.id,
        select: {source, target, e},
        limit: ^limit
      )

    results = Repo.all(query)

    Enum.map(results, fn {source, target, edge} ->
      {connected_node, direction} =
        if source.id == node_id do
          {target, :outgoing}
        else
          {source, :incoming}
        end

      target_type = infer_node_type(connected_node)

      %{
        source_type: "knowledge",
        source_id: node_id,
        target_type: target_type,
        target_id: connected_node.id,
        link_type: Atom.to_string(edge.edge_type),
        confidence: edge.confidence || edge.weight || 0.7,
        discovered_by: "graph_traversal",
        direction: direction
      }
    end)
  rescue
    _ -> []
  end

  # ==========================================================================
  # Private: Helper Functions
  # ==========================================================================

  defp infer_source_type(item) do
    cond do
      item[:embedding] || item[:content] -> :memory
      item[:symbol] || item[:file_path] -> :code_symbol
      item[:package] || item[:ecosystem] -> :library
      item[:node_type] || item[:relationships] -> :knowledge
      true -> :memory
    end
  end

  defp infer_node_type(node) do
    case node.node_type do
      :file -> "code_symbol"
      :function -> "code_symbol"
      :module -> "code_symbol"
      :external_lib -> "library"
      :concept -> "knowledge"
      :memory -> "memory"
      _ -> "knowledge"
    end
  end

  defp count_inline_connections(item) do
    # Count cross-modality markers in the item itself
    connections = 0

    connections = connections + if item[:file_path] || item[:symbol], do: 1, else: 0
    connections = connections + if item[:package] || item[:ecosystem], do: 1, else: 0
    connections = connections + if item[:relationships] || item[:node_type], do: 1, else: 0
    connections = connections + if item[:embedding] && item[:content], do: 1, else: 0

    # Also check explicit cross_modality field
    case item[:cross_modality] || item[:cross_modality_connections] do
      list when is_list(list) -> max(connections, length(list))
      count when is_integer(count) -> max(connections, count)
      _ -> connections
    end
  end
end
