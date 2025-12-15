defmodule Mimo.Tools.Dispatchers.Knowledge do
  @moduledoc """
  Knowledge graph operations dispatcher.

  Handles unified knowledge graph operations combining SemanticStore and Synapse:
  - query: Search both stores (SemanticStore.Repository + Synapse.QueryEngine)
  - teach: Add facts (SemanticStore.Ingestor)
  - traverse: Graph walk (Synapse.Traversal.bfs)
  - explore: Structured exploration (Synapse.QueryEngine.explore)
  - node: Get node context (Synapse.QueryEngine.node_context)
  - path: Find path (Synapse.Traversal.shortest_path)
  - stats: Statistics (both stores)
  - link: Link code to graph (Synapse.Linker)
  - link_memory: Link memory to code (Brain.MemoryLinker)
  - sync_dependencies: Sync project deps (Synapse.DependencySync)
  - neighborhood: Get nearby nodes (Synapse.PathFinder.neighborhood)

  Also handles legacy 'graph' tool operations (redirected here).
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Mimo.Tools.Helpers
  alias Mimo.Utils.InputValidation

  @doc """
  Dispatch knowledge operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "query"
    do_dispatch(op, args)
  end

  # ==========================================================================
  # Multi-Head Dispatch by Operation
  # ==========================================================================
  defp do_dispatch("query", args), do: dispatch_query(args)
  defp do_dispatch("teach", args), do: dispatch_teach(args)
  defp do_dispatch("traverse", args), do: dispatch_traverse(args)
  defp do_dispatch("explore", args), do: dispatch_explore(args)
  defp do_dispatch("node", args), do: dispatch_node(args)
  defp do_dispatch("path", args), do: dispatch_path(args)
  defp do_dispatch("stats", _args), do: dispatch_stats()
  defp do_dispatch("link", args), do: dispatch_link(args)
  defp do_dispatch("link_memory", args), do: dispatch_link_memory(args)
  defp do_dispatch("sync_dependencies", args), do: dispatch_sync_dependencies(args)
  defp do_dispatch("neighborhood", args), do: dispatch_neighborhood(args)

  defp do_dispatch(op, _args) do
    {:error,
     "Unknown knowledge operation: #{op}. Available: query, teach, traverse, explore, node, path, stats, link, link_memory, sync_dependencies, neighborhood"}
  end

  @doc """
  Dispatch for legacy 'graph' tool (same operations, just logs deprecation).
  """
  def dispatch_graph(args) do
    Logger.warning(
      "[DEPRECATED] 'graph' tool is deprecated. Use 'knowledge' tool instead with same operations."
    )

    dispatch(args)
  end

  # ==========================================================================
  # QUERY OPERATIONS
  # ==========================================================================

  defp dispatch_query(args) do
    query = args["query"]
    entity = args["entity"]
    predicate = args["predicate"]
    # Validate depth to prevent expensive recursive queries
    depth = InputValidation.validate_depth(args["depth"], default: 3)

    cond do
      entity && predicate ->
        # Structured query - use SemanticStore transitive closure
        case Mimo.SemanticStore.Query.transitive_closure(entity, "entity", predicate,
               max_depth: depth
             ) do
          results when is_list(results) and length(results) > 0 ->
            formatted =
              Enum.map(results, &%{id: &1.id, type: &1.type, depth: &1.depth, path: &1.path})

            {:ok, %{source: "semantic_store", results: formatted, count: length(results)}}

          _ ->
            # Fallback to Synapse graph search
            fallback_to_synapse_query(entity, depth)
        end

      query && query != "" ->
        # Natural language query - try both stores
        semantic_result = try_semantic_query(query)
        synapse_result = try_synapse_query(query, args)

        {:ok,
         %{
           query: query,
           semantic_store: semantic_result,
           synapse_graph: synapse_result,
           combined_count: count_results(semantic_result) + count_results(synapse_result)
         }}

      true ->
        {:error, "Query string or entity+predicate required for knowledge lookup"}
    end
  end

  defp try_semantic_query(query) do
    case Mimo.SemanticStore.Resolver.resolve_entity(query, :auto) do
      {:ok, entity_id} ->
        rels = Mimo.SemanticStore.Query.get_relationships(entity_id, "entity")
        %{found: true, entity: entity_id, relationships: rels}

      {:error, :ambiguous, candidates} ->
        %{found: false, ambiguous: true, candidates: candidates}
    end
  rescue
    _ -> %{found: false, error: "semantic_store_unavailable"}
  end

  defp try_synapse_query(query, args) do
    opts = []
    # Validate limit to prevent excessive results
    limit = InputValidation.validate_limit(args["limit"], default: 50, max: 500)
    opts = Keyword.put(opts, :max_nodes, limit)

    case Mimo.Synapse.QueryEngine.query(query, opts) do
      {:ok, result} ->
        %{
          found: length(result.nodes) > 0,
          nodes: Helpers.format_graph_nodes(result.nodes),
          count: length(result.nodes)
        }

      {:error, _reason} ->
        %{found: false}
    end
  rescue
    _ -> %{found: false, error: "synapse_unavailable"}
  end

  defp fallback_to_synapse_query(entity, depth) do
    case Mimo.Synapse.Graph.search_nodes(entity, limit: 1) do
      [node | _] ->
        results = Mimo.Synapse.Traversal.bfs(node.id, max_depth: depth)

        {:ok,
         %{
           source: "synapse_fallback",
           node: Helpers.format_graph_node(node),
           traversal: length(results)
         }}

      [] ->
        {:ok, %{source: "none", found: false, message: "No results in either knowledge store"}}
    end
  rescue
    _ -> {:ok, %{source: "none", found: false}}
  end

  defp count_results(%{count: c}), do: c
  defp count_results(%{found: true}), do: 1
  defp count_results(_), do: 0

  # ==========================================================================
  # TEACH OPERATIONS
  # ==========================================================================

  defp dispatch_teach(args) do
    text = args["text"]
    subject = args["subject"]
    predicate = args["predicate"]
    object = args["object"]
    source = args["source"] || "user_input"

    do_dispatch_teach(subject, predicate, object, text, source)
  end

  # Teaching a triple (subject, predicate, object)
  defp do_dispatch_teach(subject, predicate, object, _text, source)
       when not is_nil(subject) and not is_nil(predicate) and not is_nil(object) do
    case Mimo.SemanticStore.Ingestor.ingest_triple(
           %{subject: subject, predicate: predicate, object: object},
           source
         ) do
      {:ok, id} ->
        {:ok, %{status: "learned", triple_id: id, store: "semantic"}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to ingest triple: #{inspect(reason)}"}
    end
  end

  # Teaching from text
  defp do_dispatch_teach(_subject, _predicate, _object, text, source)
       when not is_nil(text) and text != "" do
    case Mimo.SemanticStore.Ingestor.ingest_text(text, source) do
      {:ok, count} ->
        {:ok, %{status: "learned", triples_created: count, store: "semantic"}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to ingest text: #{inspect(reason)}"}
    end
  end

  # No valid input
  defp do_dispatch_teach(_subject, _predicate, _object, _text, _source) do
    {:error, "Text or subject+predicate+object required for teaching"}
  end

  # ==========================================================================
  # GRAPH TRAVERSAL OPERATIONS
  # ==========================================================================

  defp dispatch_traverse(args) do
    node_id = args["node_id"] || args["node_name"]
    do_dispatch_traverse(node_id, args)
  end

  defp do_dispatch_traverse(node_id, _args) when is_nil(node_id) or node_id == "" do
    {:error, "node_id or node_name is required"}
  end

  defp do_dispatch_traverse(_node_id, args) do
    case resolve_node_id(args) do
      nil ->
        {:error, "Node not found"}

      actual_node_id ->
        opts = build_traverse_opts(args)
        results = Mimo.Synapse.Traversal.bfs(actual_node_id, opts)
        format_traverse_results(actual_node_id, results)
    end
  end

  defp build_traverse_opts(args) do
    []
    |> maybe_add_depth_opt(args["max_depth"])
    |> maybe_add_direction_opt(args["direction"])
  end

  defp maybe_add_depth_opt(opts, nil), do: opts

  defp maybe_add_depth_opt(opts, depth) do
    validated = InputValidation.validate_depth(depth)
    Keyword.put(opts, :max_depth, validated)
  end

  defp maybe_add_direction_opt(opts, nil), do: opts

  defp maybe_add_direction_opt(opts, direction) do
    case Helpers.safe_to_atom(direction, Helpers.allowed_directions()) do
      nil -> opts
      dir -> Keyword.put(opts, :direction, dir)
    end
  end

  defp format_traverse_results(start_node, results) do
    {:ok,
     %{
       start_node: start_node,
       results:
         Enum.map(results, fn r ->
           %{
             node: Helpers.format_graph_node(r.node),
             depth: r.depth,
             path: r.path
           }
         end),
       total: length(results)
     }}
  end

  defp dispatch_explore(args) do
    query = args["query"] || ""

    if query == "" do
      {:error, "Query is required for explore"}
    else
      # Validate limit to prevent excessive results
      limit = InputValidation.validate_limit(args["limit"], default: 50, max: 500)
      opts = [limit: limit]
      Mimo.Synapse.QueryEngine.explore(query, opts)
    end
  end

  defp dispatch_node(args) do
    node_id = args["node_id"] || args["node_name"]

    if is_nil(node_id) or node_id == "" do
      {:error, "node_id or node_name is required"}
    else
      actual_node_id = resolve_node_id(args)

      if actual_node_id do
        hops = args["max_depth"] || 2

        case Mimo.Synapse.QueryEngine.node_context(actual_node_id, hops: hops) do
          {:ok, result} ->
            {:ok,
             %{
               node: Helpers.format_graph_node(result.node),
               neighbors: Helpers.format_graph_nodes(result.neighbors),
               context: result.context,
               edges: length(result.edges)
             }}

          {:error, reason} ->
            {:error, "Node context failed: #{inspect(reason)}"}
        end
      else
        {:error, "Node not found"}
      end
    end
  end

  defp dispatch_path(args) do
    from_node = args["from_node"]
    to_node = args["to_node"]

    if is_nil(from_node) or is_nil(to_node) do
      {:error, "from_node and to_node are required"}
    else
      opts = if args["max_depth"], do: [max_depth: args["max_depth"]], else: []

      case Mimo.Synapse.Traversal.shortest_path(from_node, to_node, opts) do
        {:ok, path} ->
          {:ok,
           %{
             from: from_node,
             to: to_node,
             path: path,
             length: length(path) - 1
           }}

        {:error, :no_path} ->
          {:ok,
           %{
             from: from_node,
             to: to_node,
             path: [],
             error: "No path found"
           }}
      end
    end
  end

  # ==========================================================================
  # STATS, LINK, SYNC OPERATIONS
  # ==========================================================================

  defp dispatch_stats do
    synapse_stats = Mimo.Synapse.Graph.stats()

    semantic_count =
      try do
        Mimo.Repo.one(from(t in Mimo.SemanticStore.Triple, select: count(t.id))) || 0
      rescue
        _ -> 0
      end

    {:ok,
     %{
       semantic_store: %{triples: semantic_count},
       synapse_graph: synapse_stats,
       total_knowledge_items: semantic_count + (synapse_stats[:total_nodes] || 0)
     }}
  end

  defp dispatch_link(args) do
    path = args["path"]

    if is_nil(path) or path == "" do
      {:error, "Path is required for link operation"}
    else
      result =
        if File.dir?(path) do
          # Use optimized linker for directories (50x faster)
          Mimo.Synapse.LinkerOptimized.link_directory(path)
        else
          Mimo.Synapse.Linker.link_code_file(path)
        end

      # Format GraphNode struct for JSON serialization
      case result do
        {:ok, res} when is_map(res) ->
          formatted_res = Map.update(res, :file_node, nil, &Helpers.format_graph_node/1)
          {:ok, formatted_res}

        other ->
          other
      end
    end
  end

  defp dispatch_link_memory(args) do
    memory_id = args["memory_id"]

    if is_nil(memory_id) or memory_id == "" do
      {:error, "memory_id is required for link_memory operation"}
    else
      case Mimo.Repo.get(Mimo.Brain.Engram, memory_id) do
        nil ->
          {:error, "Memory not found: #{memory_id}"}

        memory ->
          result = Mimo.Brain.MemoryLinker.link_memory(memory_id, memory.content)

          {:ok,
           %{
             memory_id: memory_id,
             linked_files: length(result[:linked_files] || []),
             linked_functions: length(result[:linked_functions] || []),
             linked_libraries: length(result[:linked_libraries] || []),
             details: result
           }}
      end
    end
  end

  defp dispatch_sync_dependencies(args) do
    path = args["path"] || File.cwd!()

    case Mimo.Synapse.DependencySync.sync_dependencies(path) do
      {:ok, result} ->
        {:ok,
         %{
           path: path,
           synced_files: result[:synced_files] || [],
           total_dependencies: result[:total_dependencies] || 0,
           ecosystems: result[:ecosystems] || [],
           details: result
         }}

      {:error, reason} ->
        {:error, "Failed to sync dependencies: #{inspect(reason)}"}
    end
  end

  defp dispatch_neighborhood(args) do
    depth = InputValidation.validate_depth(args["depth"], default: 2)
    limit = InputValidation.validate_limit(args["limit"], default: 50, max: 500)

    node = find_neighborhood_node(args["node_id"], args["node_name"], args["node_type"])
    do_dispatch_neighborhood(node, depth, limit)
  end

  defp find_neighborhood_node(node_id, _node_name, _node_type) when not is_nil(node_id) do
    Mimo.Repo.get(Mimo.Synapse.GraphNode, node_id)
  end

  defp find_neighborhood_node(_node_id, node_name, node_type) when not is_nil(node_name) do
    type = Helpers.parse_node_type(node_type)
    Mimo.Synapse.Graph.get_node(type, node_name)
  end

  defp find_neighborhood_node(_node_id, _node_name, _node_type), do: nil

  defp do_dispatch_neighborhood(nil, _depth, _limit) do
    {:error, "Node not found. Provide node_id or node_name (with optional node_type)"}
  end

  defp do_dispatch_neighborhood(node, depth, limit) do
    case Mimo.Synapse.PathFinder.neighborhood(node.id, depth: depth, limit: limit) do
      {:ok, result} ->
        {:ok, format_neighborhood_result(node, depth, result)}

      {:error, reason} ->
        {:error, "Failed to get neighborhood: #{inspect(reason)}"}
    end
  end

  defp format_neighborhood_result(node, depth, result) do
    %{
      center_node: Helpers.format_graph_node(node),
      depth: depth,
      nodes: Helpers.format_graph_nodes(result[:nodes] || []),
      edges: Helpers.format_edges(result[:edges] || []),
      node_count: length(result[:nodes] || []),
      edge_count: length(result[:edges] || [])
    }
  end

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  defp resolve_node_id(args) do
    if args["node_name"] do
      node_type = Helpers.parse_node_type(args["node_type"])

      case Mimo.Synapse.Graph.get_node(node_type, args["node_name"]) do
        nil ->
          case Mimo.Synapse.Graph.search_nodes(args["node_name"], limit: 1) do
            [node | _] -> node.id
            [] -> nil
          end

        node ->
          node.id
      end
    else
      args["node_id"]
    end
  end
end
