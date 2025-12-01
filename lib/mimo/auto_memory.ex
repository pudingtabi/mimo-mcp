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
      # RELIABILITY FIX: Use Task.Supervisor instead of Task.start for visibility
      Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
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

  # Categorize tools by their type
  defp categorize_tool(tool_name) do
    cond do
      # File operations
      String.contains?(tool_name, "read_file") ->
        {:file_read, :from_args}

      String.contains?(tool_name, "write_file") ->
        {:file_write, :from_args}

      # Search operations
      String.contains?(tool_name, "search") or String.contains?(tool_name, "vibes") ->
        {:search, :from_args}

      # Browser operations (including blink for protected sites)
      String.contains?(tool_name, "puppeteer") or String.contains?(tool_name, "browser") or
          String.contains?(tool_name, "blink") ->
        {:browser, tool_name}

      # Process/terminal operations
      String.contains?(tool_name, "process") or String.contains?(tool_name, "terminal") ->
        {:process, :from_args}

      # Fetch operations (URL reads)
      String.contains?(tool_name, "fetch") or String.contains?(tool_name, "web_extract") ->
        {:file_read, :url}

      # Skip internal memory tools (avoid recursion)
      String.contains?(tool_name, "store_fact") or
        String.contains?(tool_name, "ask_mimo") or
          String.contains?(tool_name, "mimo_") ->
        :skip

      # Skip config/utility tools
      String.contains?(tool_name, "config") or
        String.contains?(tool_name, "list_") or
          String.contains?(tool_name, "get_") ->
        :skip

      true ->
        :skip
    end
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

    content =
      cond do
        # Blink tool - record URL visits with protection info
        String.contains?(action, "blink") ->
          operation = arguments["operation"] || "fetch"
          status = get_in_result(result, ["status"]) || get_in_result(result, ["data", "status"])
          protection = get_in_result(result, ["data", "protection"])

          status_str = if status, do: " (status: #{status})", else: ""
          protection_str = if protection, do: " [protected by: #{protection}]", else: ""

          "Blink #{operation}: #{url}#{status_str}#{protection_str}"

        String.contains?(action, "navigate") and url != "" ->
          "Visited URL: #{url}"

        String.contains?(action, "screenshot") ->
          "Took screenshot#{if url != "", do: " of #{url}", else: ""}"

        String.contains?(action, "click") ->
          selector = arguments["selector"] || "element"
          "Clicked: #{selector}#{if url != "", do: " on #{url}", else: ""}"

        true ->
          Logger.debug("AutoMemory browser: No content match for action=#{action}")
          nil
      end

    if content do
      Logger.debug("AutoMemory browser: Storing content=#{content}")
      store_memory(content, "action", 0.35)
    end
  end

  defp store_browser_memory(_action, _arguments, other) do
    Logger.debug("AutoMemory browser: Pattern not matched, result=#{inspect(other)}")
    :ok
  end

  # Helper to safely get nested values from result maps (handles both atom and string keys)
  # SECURITY FIX: Use String.to_existing_atom instead of String.to_atom to prevent atom exhaustion
  defp get_in_result(result, keys) when is_map(result) and is_list(keys) do
    Enum.reduce_while(keys, result, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_map(acc) and is_binary(key) ->
          # Try existing atom, don't create new ones
          try do
            atom_key = String.to_existing_atom(key)

            if Map.has_key?(acc, atom_key) do
              {:cont, Map.get(acc, atom_key)}
            else
              {:halt, nil}
            end
          rescue
            ArgumentError -> {:halt, nil}
          end

        is_map(acc) and is_atom(key) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        true ->
          {:halt, nil}
      end
    end)
  end

  defp get_in_result(_, _), do: nil

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
  # Actually store the memory via WorkingMemory for proper consolidation
  defp store_memory(content, category, importance) do
    min_importance = Application.get_env(:mimo_mcp, :auto_memory_min_importance, 0.3)

    if importance >= min_importance do
      Logger.debug("AutoMemory storing: #{category} (importance: #{importance})")

      # Route through WorkingMemory for consolidation pipeline
      Mimo.Brain.WorkingMemory.store(content,
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
