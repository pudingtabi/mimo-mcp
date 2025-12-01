defmodule Mimo.Synapse.Linker do
  @moduledoc """
  Automatically creates edges in the Synapse Web based on:
  - Static analysis (code structure from SPEC-021)
  - Semantic analysis (text similarity via embeddings)
  - Dynamic patterns (user access patterns)

  ## Integration Points

  - **Code Symbols**: Links functions, modules, files from Tree-Sitter analysis
  - **External Libraries**: Links package dependencies from SPEC-022
  - **Memory/Engrams**: Links memories to relevant code and concepts
  - **Concepts**: Creates and links abstract concepts

  ## Example

      # Link all symbols from a file
      {:ok, stats} = Linker.link_code_file("/path/to/file.ex")

      # Link a memory to related nodes
      {:ok, count} = Linker.link_memory(engram_id)

      # Auto-categorize nodes into concepts
      {:ok, count} = Linker.auto_categorize()
  """

  require Logger
  alias Mimo.Synapse.Graph

  # ============================================
  # Code Linking (from SPEC-021 Symbol Index)
  # ============================================

  @doc """
  Link code symbols from a file to the graph.

  Creates:
  - File node
  - Function/Module nodes for each symbol
  - "defines" edges from file to symbols
  - "calls" edges between functions (from references)

  ## Returns

  `{:ok, %{file_node: node, symbols_linked: count, refs_linked: count}}`
  """
  @spec link_code_file(String.t()) :: {:ok, map()} | {:error, term()}
  def link_code_file(file_path) do
    # Check if file exists
    if File.exists?(file_path) do
      do_link_code_file(file_path)
    else
      {:error, :file_not_found}
    end
  end

  defp do_link_code_file(file_path) do
    # Get symbols and references from the code symbol index
    symbols = get_code_symbols(file_path)
    references = get_code_references(file_path)

    # Create file node
    {:ok, file_node} =
      Graph.find_or_create_node(:file, file_path, %{
        language: detect_language(file_path),
        indexed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # Create nodes for each symbol
    symbol_nodes =
      symbols
      |> Enum.map(fn symbol ->
        node_type = symbol_kind_to_node_type(symbol.kind)
        name = symbol.qualified_name || symbol.name

        {:ok, node} =
          Graph.find_or_create_node(node_type, name, %{
            language: symbol.language,
            visibility: symbol.visibility || "public",
            file_path: file_path,
            start_line: symbol.start_line,
            end_line: symbol.end_line,
            signature: symbol.signature,
            doc: symbol.doc
          })

        # Link file -> symbol (defines)
        Graph.ensure_edge(file_node.id, node.id, :defines, %{source: "static_analysis"})

        {symbol.name, node}
      end)
      |> Map.new()

    # Create edges for references (calls, imports)
    refs_linked =
      references
      |> Enum.map(fn ref ->
        source_node = Map.get(symbol_nodes, ref.source_name)
        target_node = find_or_create_ref_target(ref, symbol_nodes)

        if source_node && target_node do
          edge_type = reference_kind_to_edge_type(ref.kind)

          Graph.ensure_edge(source_node.id, target_node.id, edge_type, %{
            source: "static_analysis",
            line: ref.line
          })

          1
        else
          0
        end
      end)
      |> Enum.sum()

    {:ok,
     %{
       file_node: file_node,
       symbols_linked: map_size(symbol_nodes),
       refs_linked: refs_linked
     }}
  rescue
    e ->
      Logger.error("Failed to link code file #{file_path}: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Link an external library to the graph.

  Creates an external_lib node with package metadata, or updates
  an existing node with the same name.
  """
  @spec link_external_library(map()) :: {:ok, Graph.GraphNode.t()} | {:error, term()}
  def link_external_library(library_info) do
    name = library_info[:name] || library_info["name"]
    ecosystem = library_info[:ecosystem] || library_info["ecosystem"] || "unknown"

    properties = %{
      ecosystem: to_string(ecosystem),
      version: library_info[:version] || library_info["version"],
      description: library_info[:description] || library_info["description"],
      docs_url: library_info[:docs_url] || library_info["docs_url"],
      linked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Check if node exists and update if so
    case Graph.get_node(:external_lib, name) do
      nil ->
        Graph.create_node(%{
          node_type: :external_lib,
          name: name,
          properties: properties
        })

      existing ->
        # Merge properties, preferring new values
        merged = Map.merge(existing.properties || %{}, stringify_keys(properties))
        Graph.update_node(existing, %{properties: merged})
    end
  end

  # ============================================
  # Memory Linking (Semantic)
  # ============================================

  @doc """
  Link a memory/engram to related nodes via semantic similarity.

  Uses the memory's embedding to find similar nodes in the graph.

  ## Options

    - `:threshold` - Minimum similarity threshold (default: 0.7)
    - `:max_links` - Maximum number of links to create (default: 5)
  """
  @spec link_memory(integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def link_memory(engram_id, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.7)
    max_links = Keyword.get(opts, :max_links, 5)

    case get_engram(engram_id) do
      {:error, _} ->
        {:error, :engram_not_found}

      nil ->
        {:error, :engram_not_found}

      {:ok, engram} ->
        # Create memory node
        {:ok, memory_node} =
          Graph.find_or_create_node(:memory, "engram_#{engram_id}", %{
            content_preview: String.slice(engram.content || "", 0, 200),
            category: engram.category,
            importance: engram.importance,
            source_ref_type: "engram",
            source_ref_id: to_string(engram_id)
          })

        edges_created =
          if engram.embedding && length(engram.embedding) > 0 do
            # Find similar nodes by embedding
            similar_nodes = find_similar_nodes(engram.embedding, threshold, max_links)

            # Create "mentions" edges
            Enum.map(similar_nodes, fn {node, _similarity} ->
              case Graph.ensure_edge(memory_node.id, node.id, :mentions, %{
                     source: "semantic_inference",
                     created_at: DateTime.utc_now() |> DateTime.to_iso8601()
                   }) do
                {:ok, _} -> 1
                _ -> 0
              end
            end)
            |> Enum.sum()
          else
            0
          end

        # Also link by entity extraction
        entity_edges = link_memory_entities(memory_node, engram.content)

        {:ok, edges_created + entity_edges}
    end
  end

  @doc """
  Link memory to nodes by extracting entity mentions from content.
  """
  @spec link_memory_entities(Graph.GraphNode.t(), String.t() | nil) :: non_neg_integer()
  def link_memory_entities(_memory_node, nil), do: 0
  def link_memory_entities(_memory_node, ""), do: 0

  def link_memory_entities(memory_node, content) do
    # Extract potential entity mentions
    entities = extract_entities(content)

    # Find matching nodes for each entity
    Enum.map(entities, fn entity ->
      case find_matching_node(entity) do
        nil ->
          0

        node ->
          case Graph.ensure_edge(memory_node.id, node.id, :mentions, %{
                 source: "entity_extraction",
                 entity: entity
               }) do
            {:ok, _} -> 1
            _ -> 0
          end
      end
    end)
    |> Enum.sum()
  end

  # ============================================
  # Concept Management
  # ============================================

  @doc """
  Create or update a concept node.

  ## Options

    - `:description` - Human-readable description of the concept
    - `:properties` - Additional metadata as a map

  ## Examples

      {:ok, concept} = create_concept("Authentication", description: "User auth")
      {:ok, concept} = create_concept("Testing", properties: %{"priority" => "high"})
  """
  @spec create_concept(String.t(), keyword() | map()) ::
          {:ok, Graph.GraphNode.t()} | {:error, term()}
  def create_concept(name, opts \\ [])

  def create_concept(name, opts) when is_list(opts) do
    # Extract known fields from keyword options
    description = Keyword.get(opts, :description)
    properties = Keyword.get(opts, :properties, %{})

    # Convert properties atom keys to strings
    properties = stringify_keys(properties)

    # Build node attributes
    attrs = %{
      node_type: :concept,
      name: name,
      properties: properties
    }

    attrs = if description, do: Map.put(attrs, :description, description), else: attrs

    # Use find_or_create_node internally but handle all attrs
    case Graph.get_node(:concept, name) do
      nil ->
        Graph.create_node(attrs)

      existing ->
        {:ok, existing}
    end
  end

  def create_concept(name, properties) when is_map(properties) do
    # When a map is passed directly, treat it as properties
    create_concept(name, properties: properties)
  end

  # Convert atom keys to string keys for consistency
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(value), do: value

  @doc """
  Link a node to a concept (implements relationship).
  """
  @spec link_to_concept(String.t(), String.t()) :: {:ok, Graph.GraphEdge.t()} | {:error, term()}
  def link_to_concept(node_id, concept_name) do
    {:ok, concept_node} = Graph.find_or_create_node(:concept, concept_name)
    Graph.ensure_edge(node_id, concept_node.id, :implements, %{source: "manual"})
  end

  @doc """
  Auto-categorize nodes into concepts based on naming patterns.

  Scans all function/module nodes and links them to relevant concepts
  based on common patterns (auth, database, api, etc.).

  ## Returns

  `{:ok, edges_created}`
  """
  @spec auto_categorize() :: {:ok, non_neg_integer()}
  def auto_categorize do
    patterns = [
      {~r/auth|login|session|password|credential/i, "Authentication"},
      {~r/database|db|repo|query|migration|schema/i, "Database"},
      {~r/api|endpoint|route|controller|handler/i, "API"},
      {~r/cache|redis|ets|memcache/i, "Caching"},
      {~r/test|spec|assert|expect/i, "Testing"},
      {~r/log|logger|telemetry|metric/i, "Observability"},
      {~r/email|mail|smtp|notification/i, "Notifications"},
      {~r/error|exception|rescue|catch|fallback/i, "Error Handling"},
      {~r/config|settings|env|environment/i, "Configuration"},
      {~r/parse|transform|convert|encode|decode/i, "Data Processing"},
      {~r/file|path|io|stream/i, "File Operations"},
      {~r/http|request|response|client/i, "HTTP"},
      {~r/json|xml|yaml|csv/i, "Serialization"},
      {~r/worker|job|queue|async|task/i, "Background Jobs"},
      {~r/websocket|socket|channel|pubsub/i, "Real-time"}
    ]

    # Get all function and module nodes
    nodes =
      Graph.find_by_type(:function, limit: 1000) ++
        Graph.find_by_type(:module, limit: 1000)

    count =
      nodes
      |> Enum.flat_map(fn node ->
        # Find matching concepts
        patterns
        |> Enum.filter(fn {regex, _concept} -> Regex.match?(regex, node.name) end)
        |> Enum.map(fn {_regex, concept} ->
          {:ok, concept_node} = create_concept(concept)

          case Graph.ensure_edge(node.id, concept_node.id, :implements, %{
                 source: "auto_categorize"
               }) do
            {:ok, _edge} -> 1
            _ -> 0
          end
        end)
      end)
      |> Enum.sum()

    {:ok, count}
  end

  # ============================================
  # Bulk Linking Operations
  # ============================================

  @doc """
  Link all code files in a directory to the graph.

  ## Options

    - `:recursive` - Recurse into subdirectories (default: true)
    - `:extensions` - File extensions to include (default: [".ex", ".exs", ".py", ".js", ".ts"])
  """
  @spec link_directory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def link_directory(dir_path, opts \\ []) do
    # Check if directory exists
    if File.dir?(dir_path) do
      do_link_directory(dir_path, opts)
    else
      {:error, :directory_not_found}
    end
  end

  defp do_link_directory(dir_path, opts) do
    recursive = Keyword.get(opts, :recursive, true)
    extensions = Keyword.get(opts, :extensions, [".ex", ".exs", ".py", ".js", ".ts", ".tsx"])

    files =
      if recursive do
        Path.wildcard(Path.join(dir_path, "**/*"))
      else
        Path.wildcard(Path.join(dir_path, "*"))
      end
      |> Enum.filter(fn path ->
        File.regular?(path) && Path.extname(path) in extensions
      end)

    results =
      files
      |> Enum.map(fn file ->
        case link_code_file(file) do
          {:ok, stats} -> {:ok, stats}
          {:error, _} -> {:error, file}
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, _}, &1))

    total_symbols = Enum.reduce(successes, 0, fn {:ok, s}, acc -> acc + s.symbols_linked end)
    total_refs = Enum.reduce(successes, 0, fn {:ok, s}, acc -> acc + s.refs_linked end)

    {:ok,
     %{
       files_processed: length(successes),
       files_failed: length(failures),
       total_symbols: total_symbols,
       total_references: total_refs
     }}
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp get_code_symbols(file_path) do
    # Try to get from SymbolIndex if available
    try do
      Mimo.Code.SymbolIndex.symbols_in_file(file_path)
    rescue
      _ -> []
    end
  end

  defp get_code_references(file_path) do
    # Try to get from SymbolIndex if available
    try do
      Mimo.Code.SymbolIndex.references_in_file(file_path)
    rescue
      _ -> []
    end
  end

  defp get_engram(engram_id) do
    try do
      Mimo.Brain.Memory.get_memory(engram_id)
    rescue
      _ -> nil
    end
  end

  defp find_similar_nodes(embedding, threshold, limit)
       when is_list(embedding) and length(embedding) > 0 do
    # Query all nodes that have embeddings
    import Ecto.Query
    alias Mimo.Repo
    alias Mimo.Synapse.GraphNode

    try do
      # Get nodes with non-empty embeddings
      nodes_with_embeddings =
        GraphNode
        |> where([n], fragment("length(?) > 2", n.embedding))
        |> limit(^(limit * 10))
        |> Repo.all()
        |> Enum.filter(fn node ->
          is_list(node.embedding) and length(node.embedding) > 0
        end)

      if Enum.empty?(nodes_with_embeddings) do
        []
      else
        # Extract embeddings for batch similarity
        corpus = Enum.map(nodes_with_embeddings, & &1.embedding)

        # Use Vector.Math for efficient similarity computation
        case Mimo.Vector.Math.batch_similarity(embedding, corpus) do
          {:ok, similarities} ->
            nodes_with_embeddings
            |> Enum.zip(similarities)
            |> Enum.filter(fn {_node, score} -> score >= threshold end)
            |> Enum.sort_by(fn {_node, score} -> score end, :desc)
            |> Enum.take(limit)
            |> Enum.map(fn {node, score} -> %{node: node, similarity: score} end)

          {:error, _reason} ->
            []
        end
      end
    rescue
      e ->
        Logger.warning("find_similar_nodes failed: #{Exception.message(e)}")
        []
    end
  end

  defp find_similar_nodes(_embedding, _threshold, _limit) do
    # Empty or invalid embedding - return empty
    []
  end

  defp symbol_kind_to_node_type("function"), do: :function
  defp symbol_kind_to_node_type("method"), do: :function
  defp symbol_kind_to_node_type("module"), do: :module
  defp symbol_kind_to_node_type("class"), do: :module
  defp symbol_kind_to_node_type("interface"), do: :module
  defp symbol_kind_to_node_type(_), do: :function

  defp reference_kind_to_edge_type("call"), do: :calls
  defp reference_kind_to_edge_type("calls"), do: :calls
  defp reference_kind_to_edge_type("import"), do: :imports
  defp reference_kind_to_edge_type("imports"), do: :imports
  defp reference_kind_to_edge_type("extends"), do: :implements
  defp reference_kind_to_edge_type("implements"), do: :implements
  defp reference_kind_to_edge_type("use"), do: :uses
  defp reference_kind_to_edge_type("uses"), do: :uses
  defp reference_kind_to_edge_type(_), do: :uses

  defp find_or_create_ref_target(ref, symbol_nodes) do
    # First try to find in local symbols
    case Map.get(symbol_nodes, ref.target_name) do
      nil ->
        # Check if it's an external module
        if external_module?(ref.target_name) do
          {:ok, node} =
            Graph.find_or_create_node(:external_lib, ref.target_name, %{
              inferred: true
            })

          node
        else
          # Try to find existing node
          Graph.search_nodes(ref.target_name, limit: 1) |> List.first()
        end

      node ->
        node
    end
  end

  defp external_module?(name) do
    # Heuristics for detecting external modules
    cond do
      # Elixir stdlib/OTP modules
      String.starts_with?(name, "Enum") -> true
      String.starts_with?(name, "Map") -> true
      String.starts_with?(name, "List") -> true
      String.starts_with?(name, "String") -> true
      String.starts_with?(name, "File") -> true
      String.starts_with?(name, "IO") -> true
      String.starts_with?(name, "Logger") -> true
      String.starts_with?(name, "GenServer") -> true
      String.starts_with?(name, "Agent") -> true
      String.starts_with?(name, "Task") -> true
      # Erlang modules
      String.starts_with?(name, ":") -> true
      # Common external libraries
      String.starts_with?(name, "Phoenix") -> true
      String.starts_with?(name, "Ecto") -> true
      String.starts_with?(name, "Plug") -> true
      String.starts_with?(name, "Jason") -> true
      String.starts_with?(name, "Req") -> true
      true -> false
    end
  end

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".py" -> "python"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".jsx" -> "javascript"
      ".rb" -> "ruby"
      ".go" -> "go"
      ".rs" -> "rust"
      _ -> "unknown"
    end
  end

  defp extract_entities(text) do
    # Extract potential entity mentions:
    # - CamelCase words (likely module/class names)
    # - snake_case words with underscores (likely function names)
    # - Quoted strings that look like paths

    camel_case = ~r/\b[A-Z][a-z]+(?:[A-Z][a-z]+)+\b/
    module_path = ~r/\b[A-Z][a-z]+(?:\.[A-Z][a-z]+)+\b/
    snake_case = ~r/\b[a-z]+(?:_[a-z]+)+\b/

    camel_matches = Regex.scan(camel_case, text) |> List.flatten()
    module_matches = Regex.scan(module_path, text) |> List.flatten()
    snake_matches = Regex.scan(snake_case, text) |> List.flatten()

    (camel_matches ++ module_matches ++ snake_matches)
    |> Enum.uniq()
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp find_matching_node(entity) do
    # Try different node types
    # Try search as fallback
    Graph.get_node(:function, entity) ||
      Graph.get_node(:module, entity) ||
      Graph.get_node(:concept, entity) ||
      Graph.get_node(:external_lib, entity) ||
      Graph.search_nodes(entity, limit: 1) |> List.first()
  end
end
