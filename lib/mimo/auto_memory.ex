defmodule Mimo.AutoMemory do
  @moduledoc """
  Automatic memory layer for tool interactions.

  Intercepts tool calls and automatically stores relevant information
  as episodic memories. This makes Mimo a "memory-aware" gateway that
  learns from all AI interactions.

  ## What Gets Stored

  - File reads/writes: Content summaries, paths, operations
  - Search results: Queries and findings
  - Browser actions: URLs visited, screenshots taken
  - Process outputs: Commands executed and results
  - Errors: Failed operations for debugging context

  ## Configuration

  ```elixir
  config :mimo_mcp, :auto_memory,
    enabled: true,
    min_importance: 0.3,
    categories: [:file_ops, :search, :browser, :process, :errors]
  ```
  """
  alias SafeMemory
  require Logger

  @doc """
  Wrap a tool call with automatic memory storage.
  Returns the original result unchanged.
  """
  def wrap_tool_call(tool_name, arguments, result) do
    if enabled?() do
      # RELIABILITY FIX: Use Mimo.Sandbox.run_async for proper sandbox synchronization
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        try do
          maybe_store_memory(tool_name, arguments, result)
        rescue
          e ->
            # Emit telemetry for monitoring/alerting
            :telemetry.execute(
              [:mimo, :auto_memory, :failure],
              %{count: 1},
              %{tool: tool_name, error: Exception.message(e)}
            )

            Logger.warning("AutoMemory storage failed for #{tool_name}: #{Exception.message(e)}")
        end
      end)
    end

    result
  end

  @doc """
  Check if auto-memory is enabled.
  """
  def enabled? do
    Application.get_env(:mimo_mcp, :auto_memory_enabled, true)
  end

  # Determine if and how to store memory based on tool and result
  defp maybe_store_memory(tool_name, arguments, result) do
    Logger.debug("AutoMemory: Processing tool=#{tool_name}")

    case categorize_tool(tool_name) do
      # Unified file tool - route based on operation
      {:file_op, :check_operation} ->
        handle_file_operation(arguments, result)

      # Terminal/process execution
      {:process, _} ->
        store_process_memory(:from_args, arguments, result)

      # Web operations
      {:web_op, :check_operation} ->
        handle_web_operation(arguments, result)

      # Code intelligence operations
      {:code_op, :check_operation} ->
        handle_code_operation(arguments, result)

      # Knowledge graph operations
      {:knowledge_op, :check_operation} ->
        handle_knowledge_operation(arguments, result)

      # Reasoning operations - valuable for learning
      {:reason_op, _} ->
        handle_reason_operation(arguments, result)

      # Meta operations
      {:meta_op, :check_operation} ->
        handle_meta_operation(arguments, result)

      # Cognitive operations
      {:cognitive_op, :check_operation} ->
        handle_cognitive_operation(arguments, result)

      # Legacy file read
      {:file_read, path} ->
        Logger.debug("AutoMemory: Categorized as file_read")
        store_file_read_memory(path, arguments, result)

      # Legacy file write
      {:file_write, path} ->
        Logger.debug("AutoMemory: Categorized as file_write")
        store_file_write_memory(path, arguments, result)

      # Legacy search
      {:search, query} ->
        Logger.debug("AutoMemory: Categorized as search")
        store_search_memory(query, arguments, result)

      :skip ->
        Logger.debug("AutoMemory: Skipped tool=#{tool_name}")
        :ok
    end
  end

  # Handle unified file tool operations
  defp handle_file_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "read"
    path = arguments["path"] || arguments["name"] || "unknown"

    case operation do
      op when op in ["read", "read_lines", "read_multiple"] ->
        content = extract_content_string(result)

        if String.length(content) > 50 do
          store_memory(
            "Read #{path}: #{summarize_content(content, 200)}",
            "observation",
            calculate_importance(content)
          )
        end

      op when op in ["write", "edit", "replace_string", "multi_replace"] ->
        # Phase 3 Enhancement: Include more meaningful change details
        old_content = arguments["old_str"] || arguments["target_content"] || ""
        new_content = arguments["new_str"] || arguments["replacement_content"] || ""
        description = summarize_edit_change(op, path, old_content, new_content)

        store_memory(
          description,
          "action",
          calculate_edit_importance(op, old_content, new_content)
        )

      op when op in ["find_definition", "find_references", "symbols", "call_graph"] ->
        # Store code navigation for learning patterns
        name = arguments["name"] || arguments["pattern"] || ""
        result_count = get_result_count(result)

        if result_count > 0 do
          store_memory(
            "Code navigation: #{op} '#{name}' found #{result_count} results",
            "observation",
            0.5
          )
        end

      op when op in ["search", "glob"] ->
        pattern = arguments["pattern"] || ""
        result_count = get_result_count(result)

        if result_count > 0 do
          store_memory(
            "File search: #{op} '#{pattern}' found #{result_count} matches",
            "observation",
            0.4
          )
        end

      _ ->
        :ok
    end
  end

  defp handle_file_operation(_, _), do: :ok

  # Handle web tool operations
  defp handle_web_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "fetch"
    url = arguments["url"] || ""

    case operation do
      op when op in ["fetch", "extract", "browser", "blink", "blink_smart"] ->
        if url != "" do
          status = get_in_result(result, ["status"]) || get_in_result(result, ["data", "status"])

          store_memory(
            "Web fetch: #{url}#{if status, do: " (status: #{status})", else: ""}",
            "action",
            0.4
          )
        end

      op when op in ["search", "code_search"] ->
        query = arguments["query"] || ""

        if query != "" do
          result_count = get_result_count(result)

          store_memory(
            "Web search: '#{query}' returned #{result_count} results",
            "observation",
            0.6
          )
        end

      "screenshot" ->
        store_memory(
          "Screenshot captured#{if url != "", do: " of #{url}", else: ""}",
          "action",
          0.3
        )

      "vision" ->
        image = arguments["image"] || ""
        store_memory("Vision analysis: #{summarize_content(image, 50)}", "observation", 0.5)

      _ ->
        :ok
    end
  end

  defp handle_web_operation(_, _), do: :ok

  # Handle code tool operations
  defp handle_code_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "symbols"

    case operation do
      op when op in ["library_get", "library_search"] ->
        name = arguments["name"] || arguments["query"] || ""
        ecosystem = arguments["ecosystem"] || "unknown"

        if name != "" do
          store_memory(
            "Library lookup: #{name} (#{ecosystem})",
            "observation",
            0.6
          )
        end

      op when op in ["diagnose", "check", "lint", "typecheck"] ->
        path = arguments["path"] || ""
        error_count = get_in_result(result, ["data", "total"]) || get_result_count(result)

        store_memory(
          "Diagnostics: #{op} on #{path} found #{error_count} issues",
          "observation",
          0.5
        )

      _ ->
        :ok
    end
  end

  defp handle_code_operation(_, _), do: :ok

  # Handle knowledge graph operations
  defp handle_knowledge_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "query"

    case operation do
      "teach" ->
        subject = arguments["subject"] || arguments["text"] || ""

        store_memory(
          "Knowledge taught: #{summarize_content(subject, 100)}",
          "fact",
          0.7
        )

      "query" ->
        query = arguments["query"] || ""
        result_count = get_result_count(result)

        if result_count > 0 do
          store_memory(
            "Knowledge query: '#{query}' returned #{result_count} results",
            "observation",
            0.4
          )
        end

      _ ->
        :ok
    end
  end

  defp handle_knowledge_operation(_, _), do: :ok

  # Handle reasoning operations - valuable for learning
  defp handle_reason_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "guided"
    problem = arguments["problem"] || arguments["thought"] || ""

    case operation do
      "guided" ->
        strategy = get_in_result(result, ["data", "strategy"]) || "unknown"

        store_memory(
          "Reasoning started: #{summarize_content(problem, 100)} (strategy: #{strategy})",
          "plan",
          0.7
        )

      "conclude" ->
        store_memory(
          "Reasoning concluded for: #{summarize_content(problem, 100)}",
          "action",
          0.6
        )

      "reflect" ->
        success = arguments["success"] || false

        store_memory(
          "Reflection: #{if success, do: "success", else: "failure"} - #{summarize_content(problem, 100)}",
          "observation",
          0.8
        )

      _ ->
        :ok
    end
  end

  defp handle_reason_operation(_, _), do: :ok

  # Handle meta operations (analyze_file, debug_error, etc.)
  defp handle_meta_operation(arguments, {:ok, _result}) do
    operation = arguments["operation"] || "analyze_file"

    case operation do
      "analyze_file" ->
        path = arguments["path"] || ""
        store_memory("Analyzed file: #{path}", "observation", 0.5)

      "debug_error" ->
        message = arguments["message"] || ""

        store_memory(
          "Debugging error: #{summarize_content(message, 100)}",
          "action",
          0.6
        )

      "prepare_context" ->
        query = arguments["query"] || ""

        store_memory(
          "Context prepared for: #{summarize_content(query, 100)}",
          "observation",
          0.4
        )

      _ ->
        :ok
    end
  end

  defp handle_meta_operation(_, _), do: :ok

  # Handle cognitive operations
  defp handle_cognitive_operation(arguments, {:ok, result}) do
    operation = arguments["operation"] || "assess"

    case operation do
      op when op in ["emergence_detect", "emergence_promote"] ->
        pattern_count = get_result_count(result)

        store_memory(
          "Emergence #{op}: detected #{pattern_count} patterns",
          "observation",
          0.7
        )

      "reflector_reflect" ->
        store_memory("Self-reflection performed", "observation", 0.6)

      _ ->
        :ok
    end
  end

  defp handle_cognitive_operation(_, _), do: :ok

  # Helper to extract count from various result formats
  defp get_result_count(result) when is_map(result) do
    cond do
      Map.has_key?(result, "count") ->
        result["count"]

      Map.has_key?(result, :count) ->
        result[:count]

      Map.has_key?(result, "data") and is_map(result["data"]) ->
        result["data"]["count"] || length(Map.get(result["data"], "results", []))

      Map.has_key?(result, :data) and is_map(result[:data]) ->
        result[:data][:count] || length(Map.get(result[:data], :results, []))

      true ->
        0
    end
  end

  defp get_result_count(result) when is_list(result), do: length(result)
  defp get_result_count(_), do: 0

  # Tool categorization patterns - updated for unified tool names (Phase 2)
  # Primary tools: file, terminal, web, code, knowledge, memory, think, reason, etc.
  @skip_patterns ["memory", "ask_mimo", "awakening", "tool_usage", "list_", "reload"]

  # Categorize tools by their type - now based on unified tool names + operation arg
  defp categorize_tool(tool_name) do
    cond do
      # Skip memory-related tools to avoid recursive storage
      matches_any?(tool_name, @skip_patterns) -> :skip
      # Unified file tool - check operation in arguments
      tool_name == "file" -> {:file_op, :check_operation}
      # Terminal/process execution
      tool_name == "terminal" -> {:process, :from_args}
      # Web operations (fetch, search, browser, etc.)
      tool_name == "web" -> {:web_op, :check_operation}
      # Code intelligence (symbols, library, diagnostics)
      tool_name == "code" -> {:code_op, :check_operation}
      # Knowledge graph operations
      tool_name == "knowledge" -> {:knowledge_op, :check_operation}
      # Reasoning operations - worth storing for learning
      tool_name == "reason" -> {:reason_op, :from_args}
      # Meta operations (analyze_file, debug_error, etc.)
      tool_name == "meta" -> {:meta_op, :check_operation}
      # Cognitive operations (emergence, reflector, verify)
      tool_name == "cognitive" -> {:cognitive_op, :check_operation}
      # Legacy patterns for backwards compatibility
      String.contains?(tool_name, "read_file") -> {:file_read, :from_args}
      String.contains?(tool_name, "write_file") -> {:file_write, :from_args}
      String.contains?(tool_name, "search") -> {:search, :from_args}
      String.contains?(tool_name, "terminal") -> {:process, :from_args}
      String.contains?(tool_name, "fetch") -> {:file_read, :url}
      true -> :skip
    end
  end

  defp matches_any?(tool_name, patterns) do
    Enum.any?(patterns, &String.contains?(tool_name, &1))
  end

  # Store memory for file reads
  # Category: "observation" - recording what was seen/read
  defp store_file_read_memory(_, arguments, {:ok, content}) do
    path = arguments["path"] || arguments["url"] || "unknown"

    # Only store if content is meaningful
    content_str = extract_content_string(content)

    if String.length(content_str) > 50 do
      summary = summarize_content(content_str, 200)

      store_memory(
        "Read file: #{path}\nContent preview: #{summary}",
        "observation",
        calculate_importance(content_str)
      )
    end
  end

  defp store_file_read_memory(_, _, _), do: :ok

  # Store memory for file writes
  # Category: "action" - recording what was done
  defp store_file_write_memory(_, arguments, {:ok, _}) do
    path = arguments["path"] || "unknown"
    content = arguments["content"] || ""

    store_memory(
      "Wrote file: #{path}\nContent: #{summarize_content(content, 150)}",
      "action",
      0.6
    )
  end

  defp store_file_write_memory(_, _, _), do: :ok

  # Store memory for search results
  # Category: "observation" - recording what was found
  defp store_search_memory(_, arguments, {:ok, results}) do
    query = arguments["query"] || arguments["pattern"] || "unknown"
    results_str = extract_content_string(results)

    if String.length(results_str) > 20 do
      store_memory(
        "Search query: #{query}\nResults: #{summarize_content(results_str, 300)}",
        "observation",
        0.7
      )
    end
  end

  defp store_search_memory(_, _, _), do: :ok

  # Helper to safely get nested values from result maps (handles both atom and string keys)
  # SECURITY FIX: Use String.to_existing_atom instead of String.to_atom to prevent atom exhaustion
  defp get_in_result(result, keys) when is_map(result) and is_list(keys) do
    Enum.reduce_while(keys, result, fn key, acc ->
      get_nested_value(acc, key)
    end)
  end

  defp get_in_result(_, _), do: nil

  # Multi-head pattern for nested value lookup
  defp get_nested_value(acc, key) when is_map(acc) and is_map_key(acc, key) do
    {:cont, Map.get(acc, key)}
  end

  defp get_nested_value(acc, key) when is_map(acc) and is_binary(key) do
    try_atom_key(acc, key)
  end

  defp get_nested_value(acc, key) when is_map(acc) and is_atom(key) do
    string_key = Atom.to_string(key)
    if Map.has_key?(acc, string_key), do: {:cont, Map.get(acc, string_key)}, else: {:halt, nil}
  end

  defp get_nested_value(_, _), do: {:halt, nil}

  # Try existing atom key (don't create new ones for security)
  defp try_atom_key(acc, key) do
    atom_key = String.to_existing_atom(key)
    if Map.has_key?(acc, atom_key), do: {:cont, Map.get(acc, atom_key)}, else: {:halt, nil}
  rescue
    ArgumentError -> {:halt, nil}
  end

  # Store memory for process/command execution
  # Category: "action" - recording commands executed
  # Note: Lower importance (0.3) for terminal outputs - they're ephemeral
  defp store_process_memory(_, arguments, {:ok, output}) do
    command = arguments["command"] || "unknown"
    output_str = extract_content_string(output)

    # Only store if output is meaningful
    if String.length(output_str) > 30 do
      store_memory(
        "Executed: #{command}\nOutput: #{summarize_content(output_str, 200)}",
        "action",
        0.3
      )
    end
  end

  defp store_process_memory(_, _, _), do: :ok
  # Actually store the memory via SafeMemory for proper consolidation
  defp store_memory(content, category, importance) do
    min_importance = Application.get_env(:mimo_mcp, :auto_memory_min_importance, 0.3)

    if importance >= min_importance do
      Logger.debug("AutoMemory storing: #{category} (importance: #{importance})")

      # Route through SafeMemory for resilient consolidation pipeline
      Mimo.Brain.SafeMemory.store(content,
        category: category,
        importance: importance,
        source: "auto_memory"
      )
    end
  end

  # Extract string content from various result formats
  defp extract_content_string(content) when is_binary(content), do: content

  defp extract_content_string(content) when is_map(content) do
    content["text"] || content["content"] || content["data"] || Jason.encode!(content)
  end

  defp extract_content_string(content) when is_list(content) do
    content |> Enum.take(5) |> Enum.map_join("\n", &extract_content_string/1)
  end

  defp extract_content_string(content), do: inspect(content)

  # Summarize content to a max length
  defp summarize_content(content, max_length) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end

  # Calculate importance based on content
  defp calculate_importance(content) do
    length = String.length(content)

    cond do
      # Large files are important
      length > 5000 -> 0.8
      length > 1000 -> 0.6
      length > 200 -> 0.4
      true -> 0.3
    end
  end

  # Generate a meaningful summary of file edits
  defp summarize_edit_change(op, path, old_content, new_content) do
    basename = Path.basename(path)
    change_type = detect_change_type(old_content, new_content)

    case op do
      "write" ->
        size = String.length(new_content)
        "Created/wrote file: #{basename} (#{size} bytes)"

      "edit" ->
        "Edited #{basename}: #{change_type}"

      "replace_string" ->
        if old_content != "" do
          "In #{basename}: replaced '#{summarize_content(old_content, 50)}' with '#{summarize_content(new_content, 50)}'"
        else
          "Modified #{basename}: #{change_type}"
        end

      "multi_replace" ->
        "Multi-edit in #{basename}: #{change_type}"

      _ ->
        "Modified #{basename} (#{op})"
    end
  end

  # Detect the type of change being made
  defp detect_change_type(old_content, new_content) do
    cond do
      old_content == "" and new_content != "" ->
        "added new content"

      old_content != "" and new_content == "" ->
        "removed content"

      String.length(new_content) > String.length(old_content) * 1.5 ->
        "significant expansion"

      String.length(new_content) < String.length(old_content) * 0.5 ->
        "significant reduction"

      String.contains?(new_content, "fix") or String.contains?(new_content, "Fix") ->
        "bug fix"

      String.contains?(new_content, "refactor") or String.contains?(new_content, "Refactor") ->
        "refactoring"

      String.contains?(new_content, "test") or String.contains?(new_content, "Test") ->
        "test update"

      true ->
        "content modification"
    end
  end

  # Calculate importance for edit operations
  defp calculate_edit_importance(op, old_content, new_content) do
    base_importance =
      case op do
        "write" -> 0.5
        "multi_replace" -> 0.7
        _ -> 0.6
      end

    # Increase importance for larger changes
    change_size = abs(String.length(new_content) - String.length(old_content))

    cond do
      change_size > 500 -> min(base_importance + 0.2, 0.9)
      change_size > 100 -> min(base_importance + 0.1, 0.8)
      true -> base_importance
    end
  end
end
