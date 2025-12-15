defmodule Mimo.Skills.MemoryContext do
  @moduledoc """
  Automatic memory context enrichment for file and terminal operations.

  Brings relevant knowledge TO the agent without requiring behavior change.
  Philosophy: Accuracy over Speed - always provide context.

  ## Usage

  When file/terminal operations execute, this module automatically:
  1. Extracts relevant query terms from the operation
  2. Searches memory for related knowledge
  3. Formats context for inclusion in response

  ## Configuration

  - `:memory_context_enabled` - Enable/disable (default: true)
  - `:memory_context_limit` - Max memories to return (default: 5)
  - `:memory_context_threshold` - Min similarity (default: 0.3)
  """

  alias Mimo.Brain.Memory

  @default_limit 5
  @default_threshold 0.3

  @doc """
  Get memory context related to a file path.

  Searches for:
  1. File-specific memories (filename, path)
  2. Conceptual memories (module purpose, patterns)
  3. Related technical decisions

  ## Examples

      iex> get_file_context("/workspace/project/src/auth/login.ts")
      {:ok, %{
        memories: [...],
        summary: "3 related memories found...",
        suggestion: "💡 Consider these..."
      }}
  """
  def get_file_context(path, opts \\ []) do
    if context_enabled?() do
      limit = Keyword.get(opts, :limit, @default_limit)
      threshold = Keyword.get(opts, :threshold, @default_threshold)

      # Build query from file path
      query_terms = build_file_query_terms(path)

      # Search memory
      case search_memories(query_terms, limit, threshold) do
        {:ok, memories} when memories != [] ->
          {:ok, format_file_context(memories, path)}

        {:ok, []} ->
          {:ok, empty_context("file", path)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Get memory context related to a terminal command.

  Searches for:
  1. Command-specific memories (tool, flags)
  2. Historical results (past errors, outputs)
  3. Environment knowledge

  ## Examples

      iex> get_command_context("npm test")
      {:ok, %{
        memories: [...],
        summary: "Found past test failures...",
        suggestion: "💡 Store results..."
      }}
  """
  def get_command_context(command, opts \\ []) do
    if context_enabled?() do
      limit = Keyword.get(opts, :limit, @default_limit)
      threshold = Keyword.get(opts, :threshold, @default_threshold)

      # Build query from command
      query_terms = build_command_query_terms(command)

      # Search memory
      case search_memories(query_terms, limit, threshold) do
        {:ok, memories} when memories != [] ->
          {:ok, format_command_context(memories, command)}

        {:ok, []} ->
          {:ok, empty_context("command", command)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Merge memory context into a tool response.

  Takes the original response data and adds memory_context field.
  """
  def enrich_response(response_data, nil), do: response_data

  def enrich_response(response_data, context) when is_map(response_data) do
    Map.put(response_data, :memory_context, context)
  end

  def enrich_response(response_data, _context), do: response_data

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp context_enabled? do
    Application.get_env(:mimo_mcp, :memory_context_enabled, true)
  end

  defp search_memories(query_terms, limit, threshold) do
    # Combine terms into a single query
    query = Enum.join(query_terms, " ")

    # Memory.search_memories returns a list directly, not {:ok, list}
    results = Memory.search_memories(query, limit: limit * 2, min_similarity: threshold)

    # Take top results, format them, and filter for quality
    memories =
      results
      |> Enum.take(limit)
      |> Enum.map(&format_memory/1)
      |> filter_quality_memories()

    {:ok, memories}
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  # Filter out low-quality memories: entity_anchors, short content, low similarity
  defp filter_quality_memories(memories) do
    Enum.filter(memories, fn m ->
      category = to_string(m.category || "")
      content = to_string(m.content || "")
      relevance = m.relevance || 0.0

      category != "entity_anchor" and
        String.length(content) > 20 and
        relevance >= 0.5
    end)
  end

  defp format_memory(memory) when is_map(memory) do
    # Handle both atom and string keys safely
    %{
      id: get_field(memory, :id),
      content: truncate_content(get_field(memory, :content), 200),
      category: get_field(memory, :category),
      relevance: safe_round(get_field(memory, :score) || get_field(memory, :similarity) || 0.0),
      age: format_age(get_field(memory, :inserted_at) || get_field(memory, :created_at))
    }
  end

  defp format_memory(_), do: %{id: nil, content: "", category: nil, relevance: 0.0, age: "unknown"}

  # Helper to get field with atom or string key
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp safe_round(value) when is_float(value), do: Float.round(value, 2)
  defp safe_round(value) when is_integer(value), do: value * 1.0
  defp safe_round(_), do: 0.0

  defp truncate_content(nil, _max_length), do: ""

  defp truncate_content(content, max_length) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end

  defp format_age(nil), do: "unknown"

  defp format_age(datetime) do
    now = DateTime.utc_now()

    # Handle both DateTime and NaiveDateTime
    datetime_utc =
      case datetime do
        %DateTime{} -> datetime
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
        _ -> now
      end

    diff_seconds = DateTime.diff(now, datetime_utc, :second)

    cond do
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)} days ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 604_800)} weeks ago"
      true -> "#{div(diff_seconds, 2_592_000)} months ago"
    end
  end

  # ===========================================================================
  # Query Building
  # ===========================================================================

  defp build_file_query_terms(path) do
    # Extract filename and directory components
    filename = Path.basename(path)
    dirname = Path.dirname(path) |> Path.basename()
    ext = Path.extname(path)
    name_without_ext = Path.basename(path, ext)

    # Build search terms
    terms =
      [
        filename,
        name_without_ext,
        dirname,
        # Common conceptual terms based on path
        extract_concepts_from_path(path)
      ]
      |> List.flatten()
      |> Enum.reject(&(is_nil(&1) or &1 == "" or &1 == "."))
      |> Enum.uniq()

    terms
  end

  defp extract_concepts_from_path(path) do
    path_lower = String.downcase(path)

    concepts = []

    # Auth-related
    concepts =
      if String.contains?(path_lower, ["auth", "login", "session", "jwt", "oauth"]) do
        ["authentication", "login", "security" | concepts]
      else
        concepts
      end

    # Config-related
    concepts =
      if String.contains?(path_lower, ["config", "settings", "env", ".env"]) do
        ["configuration", "settings", "environment" | concepts]
      else
        concepts
      end

    # Test-related
    concepts =
      if String.contains?(path_lower, ["test", "spec", "_test", ".test"]) do
        ["testing", "tests", "test cases" | concepts]
      else
        concepts
      end

    # API-related
    concepts =
      if String.contains?(path_lower, ["api", "route", "endpoint", "controller"]) do
        ["API", "endpoints", "routes" | concepts]
      else
        concepts
      end

    # Database-related
    concepts =
      if String.contains?(path_lower, ["model", "schema", "migration", "repo", "database"]) do
        ["database", "schema", "models" | concepts]
      else
        concepts
      end

    concepts
  end

  defp build_command_query_terms(command) do
    # Parse command into components
    parts = String.split(command, ~r/\s+/, trim: true)
    base_command = List.first(parts) || ""

    terms =
      [
        base_command,
        # Extract tool-specific terms
        extract_tool_concepts(base_command),
        # Include notable flags/args
        extract_notable_args(parts)
      ]
      |> List.flatten()
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    terms
  end

  defp extract_tool_concepts(command) do
    command_lower = String.downcase(command)

    cond do
      command_lower in ["npm", "yarn", "pnpm"] ->
        ["npm", "package", "dependencies", "node"]

      command_lower in ["mix", "elixir", "iex"] ->
        ["elixir", "mix", "dependencies"]

      command_lower in ["git"] ->
        ["git", "version control", "commits"]

      command_lower in ["docker", "docker-compose"] ->
        ["docker", "containers", "deployment"]

      command_lower in ["cargo", "rustc"] ->
        ["rust", "cargo", "compilation"]

      command_lower in ["python", "pip", "python3"] ->
        ["python", "pip", "packages"]

      command_lower in ["pytest", "jest", "mix test", "cargo test"] ->
        ["testing", "tests", "test results"]

      true ->
        [command_lower]
    end
  end

  defp extract_notable_args(parts) do
    parts
    # Skip the command itself
    |> Enum.drop(1)
    |> Enum.filter(fn arg ->
      # Keep meaningful args, skip flags and paths
      not String.starts_with?(arg, "-") and
        not String.starts_with?(arg, "/") and
        not String.starts_with?(arg, ".") and
        String.length(arg) > 2
    end)
    # Limit to 3 args
    |> Enum.take(3)
  end

  # ===========================================================================
  # Context Formatting
  # ===========================================================================

  defp format_file_context(memories, path) do
    filename = Path.basename(path)
    count = length(memories)

    # Group by category
    grouped = Enum.group_by(memories, & &1.category)

    # Build summary
    summary = build_summary(memories, filename)

    %{
      memories: memories,
      grouped: grouped,
      count: count,
      summary: summary,
      suggestion:
        "💡 Consider this context when working with #{filename}. Store new insights in memory."
    }
  end

  defp format_command_context(memories, command) do
    base_cmd = command |> String.split() |> List.first() || command
    count = length(memories)

    # Group by category
    grouped = Enum.group_by(memories, & &1.category)

    # Build summary
    summary = build_summary(memories, base_cmd)

    %{
      memories: memories,
      grouped: grouped,
      count: count,
      summary: summary,
      suggestion:
        "💡 Consider this context before running `#{base_cmd}`. Store important results in memory (category: action)."
    }
  end

  defp empty_context(type, target) do
    target_name =
      case type do
        "file" -> Path.basename(target)
        "command" -> target |> String.split() |> List.first() || target
      end

    %{
      memories: [],
      grouped: %{},
      count: 0,
      summary: "No prior context found for #{target_name}.",
      suggestion: "💡 This is new territory. Store valuable insights in memory as you learn."
    }
  end

  defp build_summary(memories, target) do
    count = length(memories)

    # Get top relevance scores
    top_relevance =
      memories
      |> Enum.map(& &1.relevance)
      |> Enum.max(fn -> 0 end)

    # Extract key terms from memories
    key_insights =
      memories
      |> Enum.take(2)
      |> Enum.map(& &1.content)
      |> Enum.map_join("; ", &truncate_content(&1, 50))

    if count > 0 do
      "#{count} related memories found (max relevance: #{top_relevance}). Key: #{key_insights}"
    else
      "No prior context for #{target}."
    end
  end
end
