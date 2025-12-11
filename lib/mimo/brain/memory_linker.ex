defmodule Mimo.Brain.MemoryLinker do
  @moduledoc """
  Analyzes memory content and creates links to code/concepts in Synapse graph.

  Part of SPEC-025: Cognitive Codebase Integration.

  When a memory (engram) is stored, this module:
  1. Extracts file path references from content
  2. Extracts function/module names
  3. Extracts library/package names
  4. Creates appropriate edges in the Synapse graph

  ## Extraction Strategies

  - **File paths**: `/path/to/file.ex`, `lib/module.ex`, `file.py`
  - **Function names**: `Module.function/2`, `def function(`, `function()`
  - **Library names**: `Phoenix`, `React`, `numpy` (common libraries)
  - **Concepts**: Keywords that map to existing concept nodes

  ## Example

      # After storing a memory like:
      # "Fixed authentication bug in lib/auth_service.ex by updating the verify_token/1 function"

      # MemoryLinker automatically creates:
      # memory --mentions--> file:lib/auth_service.ex
      # memory --mentions--> function:verify_token/1
      # memory --relates_to--> concept:authentication

  ## Usage

      # Called automatically by Memory.persist_memory via Orchestrator
      # Can also be called manually:
      MemoryLinker.link_memory(engram_id, content)
  """

  require Logger

  import Ecto.Query

  alias Mimo.Synapse.Graph
  alias Mimo.Repo
  alias Mimo.Brain.Engram

  # ==========================================================================
  # File Path Extraction Patterns
  # ==========================================================================

  @file_patterns [
    # Elixir/Erlang files with path
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.(?:ex|exs|erl|hrl))(?:[\s"'`\),]|$)/,
    # Python files
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.py[w]?)(?:[\s"'`\),]|$)/,
    # JavaScript/TypeScript
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.(?:js|jsx|ts|tsx|mjs|cjs))(?:[\s"'`\),]|$)/,
    # Rust
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.rs)(?:[\s"'`\),]|$)/,
    # Go
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.go)(?:[\s"'`\),]|$)/,
    # Ruby
    ~r/(?:^|[\s"'`\(])([\/\w\-\.]+\.rb)(?:[\s"'`\),]|$)/,
    # Generic lib/ or src/ paths
    ~r/(?:^|[\s"'`])(?:lib|src)\/[\w\/\-]+\.[\w]+/
  ]

  # ==========================================================================
  # Function Name Extraction Patterns
  # ==========================================================================

  @function_patterns [
    # Elixir: Module.function/arity
    ~r/([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*)\.([\w_!?]+)\/(\d+)/,
    # Elixir: Module.function()
    ~r/([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*)\.([\w_!?]+)\s*\(/,
    # Elixir: def function_name
    ~r/\bdef\s+([\w_!?]+)\s*[\(\(]/,
    # Elixir: defp private_function
    ~r/\bdefp\s+([\w_!?]+)\s*[\(\(]/,
    # Python/JS: function_name()
    ~r/\b([\w_]+)\s*\(\s*[^\)]*\)/,
    # Ruby/Python: def function_name
    ~r/\bdef\s+([\w_]+)\s*[\(\:]/
  ]

  # ==========================================================================
  # Library Name Patterns (Common Libraries)
  # ==========================================================================

  @library_patterns %{
    # Elixir/Erlang
    elixir:
      ~r/\b(?:Phoenix|Ecto|Plug|Guardian|Tesla|Req|Jason|Poison|Absinthe|GenServer|Agent|Task|Supervisor|Broadway|Oban|LiveView|Surface)\b/i,
    # Python
    python:
      ~r/\b(?:pandas|numpy|scipy|django|flask|fastapi|requests|tensorflow|pytorch|keras|matplotlib|seaborn|sqlalchemy|celery)\b/i,
    # JavaScript/TypeScript
    javascript:
      ~r/\b(?:React|Vue|Angular|Next|Express|Koa|Fastify|Lodash|Axios|Redux|MobX|GraphQL|Apollo|Prisma|TypeORM|Jest|Mocha)\b/i,
    # Rust
    rust: ~r/\b(?:tokio|serde|actix|rocket|diesel|sqlx|reqwest|clap|regex)\b/i,
    # Go
    go: ~r/\b(?:gin|echo|fiber|gorm|cobra|viper)\b/i
  }

  # ==========================================================================
  # Concept Keywords
  # ==========================================================================

  @concept_keywords %{
    "Authentication" =>
      ~r/\b(?:auth|login|logout|session|password|credential|token|jwt|oauth|sso)\b/i,
    "Database" =>
      ~r/\b(?:database|db|repo|query|migration|schema|sql|postgres|mysql|sqlite|mongo)\b/i,
    "API" => ~r/\b(?:api|endpoint|route|controller|handler|rest|graphql|grpc)\b/i,
    "Caching" => ~r/\b(?:cache|redis|ets|memcache|memoize)\b/i,
    "Testing" => ~r/\b(?:test|spec|assert|expect|mock|stub|fixture)\b/i,
    "Logging" => ~r/\b(?:log|logger|telemetry|metric|trace|debug)\b/i,
    "Error Handling" => ~r/\b(?:error|exception|rescue|catch|fallback|retry)\b/i,
    "Security" =>
      ~r/\b(?:security|encrypt|decrypt|hash|ssl|tls|vulnerability|xss|csrf|injection)\b/i,
    "Performance" => ~r/\b(?:performance|optimize|slow|fast|latency|throughput|benchmark)\b/i,
    "Configuration" => ~r/\b(?:config|settings|env|environment|variable)\b/i,
    "File Operations" => ~r/\b(?:file|path|io|stream|read|write|directory)\b/i,
    "HTTP" => ~r/\b(?:http|request|response|client|server|fetch|post|get)\b/i,
    "WebSocket" => ~r/\b(?:websocket|socket|channel|pubsub|realtime)\b/i,
    "Background Jobs" => ~r/\b(?:worker|job|queue|async|task|background|cron)\b/i,
    "Deployment" => ~r/\b(?:deploy|release|build|docker|kubernetes|k8s|ci|cd)\b/i,
    # ==========================================================================
    # Mimo-Specific Concepts (SPEC-025 Enhancement)
    # ==========================================================================
    "Memory System" =>
      ~r/\b(?:memory|engram|episodic|working[_\s]?memory|consolidat|forgett|decay|store_fact|search_vibes)\b/i,
    "Knowledge Graph" =>
      ~r/\b(?:knowledge[_\s]?graph|synapse|triple|entity|relationship|graph[_\s]?node|graph[_\s]?edge|semantic[_\s]?store)\b/i,
    "Cognitive" =>
      ~r/\b(?:cogniti|metacogniti|reason|reflect|emerge|awakening|calibrat)\b/i,
    "Code Intelligence" =>
      ~r/\b(?:symbol|definition|reference|call[_\s]?graph|diagnos|typecheck|lint)\b/i,
    "Brain" =>
      ~r/\b(?:brain|cleanup|linker|router|hybrid|retriev)\b/i,
    "Tools" =>
      ~r/\b(?:tool|skill|mcp|protocol|dispatch|orchestrat)\b/i,
    "Embedding" =>
      ~r/\b(?:embed|vector|ollama|similarity|semantic[_\s]?search)\b/i,
    "Specification" =>
      ~r/\b(?:spec[-_]?\d+|specification|implementation)\b/i
  }

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Analyze engram content and create Synapse links.

  This is the main entry point, typically called automatically
  after memory storage via the Orchestrator.

  ## Parameters

    - `engram_id` - The ID of the stored engram
    - `content` - The memory content to analyze (optional, will be fetched if not provided)

  ## Returns

    - `{:ok, %{files: n, functions: n, libraries: n, concepts: n}}` - Link counts
    - `{:error, reason}` - If linking failed
  """
  @spec link_memory(integer() | binary(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def link_memory(engram_id, content \\ nil)

  def link_memory(engram_id, nil) do
    case get_engram(engram_id) do
      {:ok, engram} ->
        link_memory(engram_id, engram.content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def link_memory(engram_id, content) when is_binary(content) do
    # Extract all references
    file_refs = extract_file_refs(content)
    function_refs = extract_function_refs(content)
    library_refs = extract_library_refs(content)
    concept_refs = extract_concept_refs(content)

    # Create/find memory node (graceful on failure)
    case find_or_create_memory_node(engram_id, content) do
      {:ok, memory_node} ->
        do_link_memory(memory_node, file_refs, function_refs, library_refs, concept_refs, engram_id)
      {:error, reason} ->
        Logger.warning("[MemoryLinker] Failed to create memory node for #{engram_id}: #{inspect(reason)}")
        {:ok, %{files: 0, functions: 0, libraries: 0, concepts: 0, total: 0, error: reason}}
    end
  end

  defp do_link_memory(memory_node, file_refs, function_refs, library_refs, concept_refs, engram_id) do

    # Create edges to referenced entities
    file_edges = create_file_edges(memory_node, file_refs)
    function_edges = create_function_edges(memory_node, function_refs)
    library_edges = create_library_edges(memory_node, library_refs)
    concept_edges = create_concept_edges(memory_node, concept_refs)

    total_edges = file_edges + function_edges + library_edges + concept_edges

    if total_edges > 0 do
      Logger.info("[MemoryLinker] Created #{total_edges} links for memory #{engram_id}")
    end

    {:ok,
     %{
       files: file_edges,
       functions: function_edges,
       libraries: library_edges,
       concepts: concept_edges,
       total: total_edges
     }}
  rescue
    e ->
      Logger.error("[MemoryLinker] Failed to link memory #{engram_id}: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Extract potential references from text without creating edges.

  Useful for previewing what would be linked.
  """
  @spec extract_references(String.t()) :: map()
  def extract_references(text) when is_binary(text) do
    %{
      files: extract_file_refs(text),
      functions: extract_function_refs(text),
      libraries: extract_library_refs(text),
      concepts: extract_concept_refs(text)
    }
  end

  def extract_references(_), do: %{files: [], functions: [], libraries: [], concepts: []}

  @doc """
  Bulk re-link all memories to the knowledge graph.

  This function is useful after updating extraction patterns or when
  graph connectivity is low. It processes all memories and creates/updates
  their links to the Synapse graph.

  ## Options

    - `:limit` - Maximum number of memories to process (default: all)
    - `:min_importance` - Only process memories with importance >= this (default: 0.0)
    - `:force` - Re-link even if already linked (default: false)

  ## Returns

    - `{:ok, %{processed: n, linked: n, failed: n, edges_created: n}}`

  ## Example

      # Re-link all memories
      MemoryLinker.bulk_relink_all()

      # Re-link only high-importance memories
      MemoryLinker.bulk_relink_all(min_importance: 0.7)

      # Re-link with limit
      MemoryLinker.bulk_relink_all(limit: 100)
  """
  @spec bulk_relink_all(keyword()) :: {:ok, map()}
  def bulk_relink_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, nil)
    min_importance = Keyword.get(opts, :min_importance, 0.0)
    force = Keyword.get(opts, :force, false)

    Logger.info("[MemoryLinker] Starting bulk re-link (min_importance: #{min_importance}, force: #{force})")

    # Query all engrams
    query = from(e in Engram,
      where: e.importance >= ^min_importance,
      order_by: [desc: e.importance],
      select: %{id: e.id, content: e.content, importance: e.importance}
    )

    query = if limit, do: limit(query, ^limit), else: query

    engrams = Repo.all(query)

    Logger.info("[MemoryLinker] Found #{length(engrams)} memories to process")

    # Process each memory
    results = engrams
    |> Enum.map(fn engram ->
      case link_memory(engram.id, engram.content) do
        {:ok, stats} ->
          {:ok, stats}
        {:error, reason} ->
          Logger.warning("[MemoryLinker] Failed to link memory #{engram.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end)

    # Aggregate stats
    successful = Enum.filter(results, fn
      {:ok, %{total: total}} when total > 0 -> true
      _ -> false
    end)

    failed = Enum.count(results, fn
      {:error, _} -> true
      _ -> false
    end)

    total_edges = results
    |> Enum.map(fn
      {:ok, %{total: total}} -> total
      _ -> 0
    end)
    |> Enum.sum()

    stats = %{
      processed: length(engrams),
      linked: length(successful),
      failed: failed,
      edges_created: total_edges
    }

    Logger.info("[MemoryLinker] Bulk re-link complete: #{inspect(stats)}")

    {:ok, stats}
  end

  @doc """
  Get connectivity statistics for the memory-graph bridge.

  Returns information about how many memories are linked to the graph
  and overall connectivity metrics.
  """
  @spec get_connectivity_stats() :: {:ok, map()}
  def get_connectivity_stats do
    # Count total memories
    total_memories = Repo.aggregate(Engram, :count)

    # Count memory nodes in graph using find_by_type
    memory_nodes_list = Graph.find_by_type(:memory, limit: 10_000)
    memory_node_count = length(memory_nodes_list)

    # Count edges from memory nodes
    memory_edges = memory_nodes_list
    |> Enum.map(fn node ->
      length(Graph.outgoing_edges(node.id, preload: false))
    end)
    |> Enum.sum()

    # Calculate connectivity ratio
    connectivity = if total_memories > 0 do
      Float.round(memory_node_count / total_memories * 100, 1)
    else
      0.0
    end

    {:ok, %{
      total_memories: total_memories,
      linked_memories: memory_node_count,
      unlinked_memories: total_memories - memory_node_count,
      total_memory_edges: memory_edges,
      connectivity_percent: connectivity,
      avg_edges_per_memory: if(memory_node_count > 0, do: Float.round(memory_edges / memory_node_count, 2), else: 0.0)
    }}
  end

  @doc """
  Link a memory to a specific node by ID.

  Creates a :mentions edge from the memory to the target node.
  """
  @spec link_to_node(integer() | binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def link_to_node(engram_id, node_id) do
    with {:ok, memory_node} <- find_or_create_memory_node(engram_id, nil),
         {:ok, edge} <- Graph.ensure_edge(memory_node.id, node_id, :mentions, %{source: "manual_link"}) do
      {:ok, %{edge_id: edge.id, memory_node_id: memory_node.id, target_node_id: node_id}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Link a memory to a concept by name.

  Creates or finds the concept node and links the memory to it.
  """
  @spec link_to_concept(integer() | binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def link_to_concept(engram_id, concept_name) do
    with {:ok, memory_node} <- find_or_create_memory_node(engram_id, nil),
         {:ok, concept_node} <- Graph.find_or_create_node(:concept, concept_name),
         {:ok, edge} <- Graph.ensure_edge(memory_node.id, concept_node.id, :relates_to, %{source: "manual_link"}) do
      {:ok, %{edge_id: edge.id, concept: concept_name}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ==========================================================================
  # Private Functions - Extraction
  # ==========================================================================

  defp extract_file_refs(text) do
    @file_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn
        [_, path | _] -> normalize_path(path)
        [path] -> normalize_path(path)
      end)
    end)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp extract_function_refs(text) do
    @function_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn
        # Module.function/arity
        [_, module, func, arity] ->
          "#{module}.#{func}/#{arity}"

        # Module.function()
        [_, module, func] when is_binary(module) ->
          if String.match?(module, ~r/^[A-Z]/) do
            "#{module}.#{func}"
          else
            nil
          end

        # Just function name
        [_, func] when is_binary(func) ->
          func

        _ ->
          nil
      end)
    end)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(String.length(&1) < 2))
    # Filter out common words that might match
    |> Enum.reject(&common_word?/1)
  end

  defp extract_library_refs(text) do
    @library_patterns
    |> Enum.flat_map(fn {_ecosystem, pattern} ->
      Regex.scan(pattern, text)
      |> Enum.map(fn [match | _] -> String.downcase(match) end)
    end)
    |> Enum.uniq()
  end

  defp extract_concept_refs(text) do
    @concept_keywords
    |> Enum.filter(fn {_concept, pattern} ->
      Regex.match?(pattern, text)
    end)
    |> Enum.map(fn {concept, _} -> concept end)
  end

  # ==========================================================================
  # Private Functions - Edge Creation
  # ==========================================================================

  defp find_or_create_memory_node(engram_id, content) do
    # Truncate content for preview
    preview = if content, do: String.slice(content, 0, 200), else: nil

    Graph.find_or_create_node(:memory, "engram_#{engram_id}", %{
      source_ref_type: "engram",
      source_ref_id: to_string(engram_id),
      content_preview: preview,
      linked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp create_file_edges(_memory_node, []), do: 0

  defp create_file_edges(memory_node, file_refs) do
    file_refs
    |> Enum.map(fn path ->
      # First try to find existing file node
      case Graph.get_node(:file, path) do
        nil ->
          # File not in graph - create it with minimal info
          case Graph.find_or_create_node(:file, path, %{
            inferred: true,
            linked_from_memory: true
          }) do
            {:ok, file_node} ->
              create_edge(memory_node.id, file_node.id, :mentions, "memory_linker")
            {:error, _reason} ->
              0
          end

        file_node ->
          create_edge(memory_node.id, file_node.id, :mentions, "memory_linker")
      end
    end)
    |> Enum.sum()
  end

  defp create_function_edges(_memory_node, []), do: 0

  defp create_function_edges(memory_node, function_refs) do
    function_refs
    |> Enum.map(fn func_name ->
      # Try to find by qualified name first, then by name
      case find_function_node(func_name) do
        nil ->
          # Function not in graph - create placeholder
          case Graph.find_or_create_node(:function, func_name, %{
            inferred: true,
            linked_from_memory: true
          }) do
            {:ok, func_node} ->
              create_edge(memory_node.id, func_node.id, :mentions, "memory_linker")
            {:error, _reason} ->
              0
          end

        func_node ->
          create_edge(memory_node.id, func_node.id, :mentions, "memory_linker")
      end
    end)
    |> Enum.sum()
  end

  defp create_library_edges(_memory_node, []), do: 0

  defp create_library_edges(memory_node, library_refs) do
    library_refs
    |> Enum.map(fn lib_name ->
      case Graph.find_or_create_node(:external_lib, lib_name, %{
        linked_from_memory: true
      }) do
        {:ok, lib_node} ->
          create_edge(memory_node.id, lib_node.id, :mentions, "memory_linker")
        {:error, _reason} ->
          0
      end
    end)
    |> Enum.sum()
  end

  defp create_concept_edges(_memory_node, []), do: 0

  defp create_concept_edges(memory_node, concept_refs) do
    concept_refs
    |> Enum.map(fn concept_name ->
      case Graph.find_or_create_node(:concept, concept_name, %{}) do
        {:ok, concept_node} ->
          create_edge(memory_node.id, concept_node.id, :relates_to, "memory_linker")
        {:error, _reason} ->
          0
      end
    end)
    |> Enum.sum()
  end

  defp create_edge(source_id, target_id, edge_type, source) do
    case Graph.ensure_edge(source_id, target_id, edge_type, %{source: source}) do
      {:ok, _} -> 1
      {:error, _} -> 0
    end
  end

  # ==========================================================================
  # Private Functions - Helpers
  # ==========================================================================

  defp get_engram(id) do
    case Repo.get(Engram, id) do
      nil -> {:error, :not_found}
      engram -> {:ok, engram}
    end
  rescue
    _ -> {:error, :db_error}
  catch
    :exit, _ -> {:error, :db_unavailable}
  end

  defp find_function_node(func_name) do
    # Try qualified name first
    # Try search
    Graph.get_node(:function, func_name) ||
      case Graph.search_nodes(func_name, types: [:function], limit: 1) do
        [node | _] -> node
        [] -> nil
      end
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing()
  end

  defp normalize_path(_), do: nil

  # Filter out common words that might match function patterns
  @common_words ~w(
    if else for while do end def defp return true false nil
    and or not in is as with from import export const let var
    class struct enum type interface module namespace
    this self super new delete typeof instanceof
    try catch finally raise throw
    print println printf echo log debug info warn error
    get set put post delete patch head options
    read write open close create update
    test describe it expect assert should
    the a an of to in on at by for with from
  )

  defp common_word?(word) when is_binary(word) do
    String.downcase(word) in @common_words
  end

  defp common_word?(_), do: false
end
