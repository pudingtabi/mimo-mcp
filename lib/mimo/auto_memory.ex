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
      Task.start(fn ->
        try do
          maybe_store_memory(tool_name, arguments, result)
        rescue
          e -> Logger.debug("AutoMemory failed: #{inspect(e)}")
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
    case categorize_tool(tool_name) do
      {:file_read, path} ->
        store_file_read_memory(path, arguments, result)

      {:file_write, path} ->
        store_file_write_memory(path, arguments, result)

      {:search, query} ->
        store_search_memory(query, arguments, result)

      {:browser, action} ->
        store_browser_memory(action, arguments, result)

      {:process, command} ->
        store_process_memory(command, arguments, result)

      {:error, _} ->
        store_error_memory(tool_name, arguments, result)

      :skip ->
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

      # Browser operations
      String.contains?(tool_name, "puppeteer") or String.contains?(tool_name, "browser") ->
        {:browser, tool_name}

      # Process/terminal operations
      String.contains?(tool_name, "process") or String.contains?(tool_name, "terminal") ->
        {:process, :from_args}

      # Fetch operations (URL reads)
      String.contains?(tool_name, "fetch") ->
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
  defp store_file_read_memory(_, arguments, {:ok, content}) do
    path = arguments["path"] || arguments["url"] || "unknown"

    # Only store if content is meaningful
    content_str = extract_content_string(content)

    if String.length(content_str) > 50 do
      summary = summarize_content(content_str, 200)

      store_memory(
        "Read file: #{path}\nContent preview: #{summary}",
        "file_read",
        calculate_importance(content_str)
      )
    end
  end

  defp store_file_read_memory(_, _, _), do: :ok

  # Store memory for file writes
  defp store_file_write_memory(_, arguments, {:ok, _}) do
    path = arguments["path"] || "unknown"
    content = arguments["content"] || ""

    store_memory(
      "Wrote file: #{path}\nContent: #{summarize_content(content, 150)}",
      "file_write",
      0.6
    )
  end

  defp store_file_write_memory(_, _, _), do: :ok

  # Store memory for search results
  defp store_search_memory(_, arguments, {:ok, results}) do
    query = arguments["query"] || arguments["pattern"] || "unknown"
    results_str = extract_content_string(results)

    if String.length(results_str) > 20 do
      store_memory(
        "Search query: #{query}\nResults: #{summarize_content(results_str, 300)}",
        "search",
        0.7
      )
    end
  end

  defp store_search_memory(_, _, _), do: :ok

  # Store memory for browser actions
  defp store_browser_memory(action, arguments, {:ok, _result}) do
    url = arguments["url"] || ""

    content =
      cond do
        String.contains?(action, "navigate") and url != "" ->
          "Visited URL: #{url}"

        String.contains?(action, "screenshot") ->
          "Took screenshot#{if url != "", do: " of #{url}", else: ""}"

        String.contains?(action, "click") ->
          selector = arguments["selector"] || "element"
          "Clicked: #{selector}#{if url != "", do: " on #{url}", else: ""}"

        true ->
          nil
      end

    if content do
      store_memory(content, "browser", 0.5)
    end
  end

  defp store_browser_memory(_, _, _), do: :ok

  # Store memory for process/command execution
  defp store_process_memory(_, arguments, {:ok, output}) do
    command = arguments["command"] || "unknown"
    output_str = extract_content_string(output)

    # Only store if output is meaningful
    if String.length(output_str) > 30 do
      store_memory(
        "Executed: #{command}\nOutput: #{summarize_content(output_str, 200)}",
        "process",
        0.5
      )
    end
  end

  defp store_process_memory(_, _, _), do: :ok

  # Store memory for errors (useful for debugging context)
  defp store_error_memory(tool_name, arguments, {:error, reason}) do
    store_memory(
      "Tool failed: #{tool_name}\nArgs: #{inspect(arguments)}\nError: #{inspect(reason)}",
      "error",
      0.4
    )
  end

  defp store_error_memory(_, _, _), do: :ok

  # Actually store the memory
  defp store_memory(content, category, importance) do
    min_importance = Application.get_env(:mimo_mcp, :auto_memory_min_importance, 0.3)

    if importance >= min_importance do
      Logger.debug("AutoMemory storing: #{category} (importance: #{importance})")

      # Use persist_memory/3 - the actual API
      Mimo.Brain.Memory.persist_memory(content, category, importance)
    end
  end

  # Extract string content from various result formats
  defp extract_content_string(content) when is_binary(content), do: content

  defp extract_content_string(content) when is_map(content) do
    content["text"] || content["content"] || content["data"] || Jason.encode!(content)
  end

  defp extract_content_string(content) when is_list(content) do
    content |> Enum.take(5) |> Enum.map(&extract_content_string/1) |> Enum.join("\n")
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
