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
      {:file_read, path} ->
        Logger.debug("AutoMemory: Categorized as file_read")
        store_file_read_memory(path, arguments, result)

      {:file_write, path} ->
        Logger.debug("AutoMemory: Categorized as file_write")
        store_file_write_memory(path, arguments, result)

      {:search, query} ->
        Logger.debug("AutoMemory: Categorized as search")
        store_search_memory(query, arguments, result)

      {:browser, action} ->
        Logger.debug("AutoMemory: Categorized as browser, action=#{action}")
        store_browser_memory(action, arguments, result)

      {:process, command} ->
        Logger.debug("AutoMemory: Categorized as process")
        store_process_memory(command, arguments, result)

      :skip ->
        Logger.debug("AutoMemory: Skipped tool=#{tool_name}")
        :ok
    end
  end

  # Tool categorization patterns - extracted for clarity and reduced complexity
  @file_read_patterns ["read_file"]
  @file_write_patterns ["write_file"]
  @search_patterns ["search", "vibes"]
  @browser_patterns ["puppeteer", "browser", "blink"]
  @process_patterns ["process", "terminal"]
  @fetch_patterns ["fetch", "web_extract"]
  @skip_patterns ["store_fact", "ask_mimo", "mimo_", "config", "list_", "get_"]

  # Categorize tools by their type using pattern matching
  defp categorize_tool(tool_name) do
    cond do
      matches_any?(tool_name, @file_read_patterns) -> {:file_read, :from_args}
      matches_any?(tool_name, @file_write_patterns) -> {:file_write, :from_args}
      matches_any?(tool_name, @search_patterns) -> {:search, :from_args}
      matches_any?(tool_name, @browser_patterns) -> {:browser, tool_name}
      matches_any?(tool_name, @process_patterns) -> {:process, :from_args}
      matches_any?(tool_name, @fetch_patterns) -> {:file_read, :url}
      matches_any?(tool_name, @skip_patterns) -> :skip
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

  # Store memory for browser actions
  # Category: "action" - recording what was done in browser
  # Note: Lower importance (0.35) for browser actions - ephemeral navigation
  defp store_browser_memory(action, arguments, {:ok, result}) do
    Logger.debug("AutoMemory browser: action=#{action}, url=#{inspect(arguments["url"])}")
    url = arguments["url"] || ""
    content = build_browser_content(action, arguments, result, url)

    if content do
      Logger.debug("AutoMemory browser: Storing content=#{content}")
      store_memory(content, "action", 0.35)
    end
  end

  defp store_browser_memory(_action, _arguments, other) do
    Logger.debug("AutoMemory browser: Pattern not matched, result=#{inspect(other)}")
    :ok
  end

  # Build browser action content - multi-head helpers
  defp build_browser_content(action, arguments, result, url) do
    browser_action_content(action, arguments, result, url)
  end

  defp browser_action_content(action, arguments, result, url) when is_binary(action) do
    cond do
      String.contains?(action, "blink") ->
        format_blink_action(arguments, result, url)

      String.contains?(action, "navigate") and url != "" ->
        "Visited URL: #{url}"

      String.contains?(action, "screenshot") ->
        format_screenshot(url)

      String.contains?(action, "click") ->
        format_click(arguments, url)

      true ->
        Logger.debug("AutoMemory browser: No content match for action=#{action}")
        nil
    end
  end

  defp format_blink_action(arguments, result, url) do
    operation = arguments["operation"] || "fetch"
    status = get_in_result(result, ["status"]) || get_in_result(result, ["data", "status"])
    protection = get_in_result(result, ["data", "protection"])

    status_str = if status, do: " (status: #{status})", else: ""
    protection_str = if protection, do: " [protected by: #{protection}]", else: ""

    "Blink #{operation}: #{url}#{status_str}#{protection_str}"
  end

  defp format_screenshot(url) do
    "Took screenshot#{if url != "", do: " of #{url}", else: ""}"
  end

  defp format_click(arguments, url) do
    selector = arguments["selector"] || "element"
    "Clicked: #{selector}#{if url != "", do: " on #{url}", else: ""}"
  end

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
end
