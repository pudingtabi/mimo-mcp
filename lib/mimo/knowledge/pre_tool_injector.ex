defmodule Mimo.Knowledge.PreToolInjector do
  @moduledoc """
  SPEC-065: Proactive Knowledge Injection Engine - Pre-Tool Injection

  Injects relevant knowledge BEFORE tool execution to provide context
  that the AI might need but hasn't asked for.

  Examples:
  - Before `file read auth.ex`, inject: "Last time auth.ex was modified, there was a bug with session tokens"
  - Before `terminal npm test`, inject: "User prefers verbose test output"

  This addresses the gap where knowledge is stored but not utilized (memory at 7.13% vs file at 52.81%).
  """

  alias Mimo.Brain.{Interaction, Memory}

  require Logger

  # Thresholds for injection
  @inject_threshold 0.7
  @high_relevance_threshold 0.85
  @max_injection_items 5
  @parallel_timeout_ms 5_000

  # Agent type injection profiles (SPEC-MULTI-AGENT)
  # Cognitive agents get rich context, action agents get minimal
  @agent_profiles %{
    # Full context - cognitive agents that benefit from deep context
    "cognitive" => %{
      max_items: 5,
      threshold: 0.65,
      include_patterns: true,
      include_warnings: true
    },
    "mimo-cognitive-agent" => %{
      max_items: 5,
      threshold: 0.65,
      include_patterns: true,
      include_warnings: true
    },
    "reasoning" => %{
      max_items: 5,
      threshold: 0.65,
      include_patterns: true,
      include_warnings: true
    },
    # Enhanced context - balanced agents
    "default" => %{
      max_items: 3,
      threshold: 0.7,
      include_patterns: true,
      include_warnings: true
    },
    "chat" => %{
      max_items: 3,
      threshold: 0.7,
      include_patterns: true,
      include_warnings: true
    },
    # Action-focused - minimal context for speed
    "action" => %{
      max_items: 2,
      threshold: 0.8,
      include_patterns: false,
      include_warnings: true
    },
    "fast" => %{
      max_items: 1,
      threshold: 0.85,
      include_patterns: false,
      include_warnings: false
    },
    # No injection for pure tool execution
    "tool" => %{
      max_items: 0,
      threshold: 1.0,
      include_patterns: false,
      include_warnings: false
    }
  }

  @type context :: %{
          file: String.t() | nil,
          command: String.t() | nil,
          type: :file_op | :terminal | :generic,
          tool: String.t() | nil,
          args: map()
        }

  @type injection :: %{
          type: :proactive_injection,
          memories: [String.t()],
          source: String.t(),
          relevance_scores: [float()]
        }

  @doc """
  Inject relevant knowledge before tool execution.

  Returns an injection map with relevant memories, or nil if none are relevant enough.

  Injection depth is controlled by agent type (from process dictionary):
  - cognitive/reasoning: Full context (5 items, lower threshold)
  - default/chat: Standard context (3 items)
  - action/fast: Minimal context (1-2 items, high threshold)
  - tool: No injection
  """
  @spec inject(String.t(), map()) :: injection() | nil
  def inject(tool_name, args) do
    profile = get_agent_profile()

    # Skip injection entirely for tool-only agents
    if profile.max_items == 0 do
      Logger.debug("[PreToolInjector] Skipping injection for agent type (max_items=0)")
      nil
    else
      context =
        extract_context(tool_name, args)
        |> Map.put(:agent_profile, profile)

      # Build task list based on profile
      tasks = build_search_tasks(context, profile)

      # Wait for tasks with timeout.
      # IMPORTANT: Task.await_many/2 can exit the caller on timeout and also leaves timed-out tasks running.
      # Under multi-instance load (SQLite locks), those runaway tasks can accumulate and cause long "hangs".
      results =
        tasks
        |> Task.yield_many(@parallel_timeout_ms)
        |> Enum.map(fn
          {_task, {:ok, result}} ->
            result

          {task, _} ->
            Task.shutdown(task, :brutal_kill)
            empty_result()
        end)

      # Unpack results based on what was included
      {memories, patterns, warnings} = unpack_search_results(results, profile)

      build_injection(memories, patterns, warnings, context)
    end
  end

  @doc """
  Get the injection profile for the current agent type.
  Reads :mimo_agent_type from process dictionary.
  """
  @spec get_agent_profile() :: map()
  def get_agent_profile do
    agent_type = Process.get(:mimo_agent_type, "default")
    Map.get(@agent_profiles, agent_type, @agent_profiles["default"])
  end

  # Build search tasks based on agent profile
  defp build_search_tasks(context, profile) do
    # Always search memories
    base_tasks = [Task.async(fn -> search_related_memories(context) end)]

    # Conditionally add patterns search
    base_tasks =
      if profile.include_patterns do
        base_tasks ++ [Task.async(fn -> search_related_patterns(context) end)]
      else
        base_tasks
      end

    # Conditionally add warnings search
    if profile.include_warnings do
      base_tasks ++ [Task.async(fn -> search_related_warnings(context) end)]
    else
      base_tasks
    end
  end

  # Unpack search results based on what was included
  defp unpack_search_results(results, %{include_patterns: true, include_warnings: true}) do
    case results do
      [m, p, w] -> {m, p, w}
      _ -> {empty_result(), empty_result(), empty_result()}
    end
  end

  defp unpack_search_results(results, %{include_patterns: true, include_warnings: false}) do
    case results do
      [m, p] -> {m, p, empty_result()}
      [m] -> {m, empty_result(), empty_result()}
      _ -> {empty_result(), empty_result(), empty_result()}
    end
  end

  defp unpack_search_results(results, %{include_patterns: false, include_warnings: true}) do
    case results do
      [m, w] -> {m, empty_result(), w}
      [m] -> {m, empty_result(), empty_result()}
      _ -> {empty_result(), empty_result(), empty_result()}
    end
  end

  defp unpack_search_results(results, %{include_patterns: false, include_warnings: false}) do
    case results do
      [m] -> {m, empty_result(), empty_result()}
      _ -> {empty_result(), empty_result(), empty_result()}
    end
  end

  @doc """
  Quick check if injection should be attempted for a tool.
  Some tools don't benefit from injection (e.g., memory operations themselves).
  """
  @spec should_inject?(String.t()) :: boolean()
  def should_inject?(tool_name) do
    # Don't inject for memory/knowledge tools (avoid recursion)
    tool_name not in ["memory", "ask_mimo", "knowledge", "onboard", "awakening_status"]
  end

  defp extract_context("file", %{"path" => path} = args) do
    %{
      file: path,
      command: nil,
      type: :file_op,
      tool: "file",
      args: args,
      filename: Path.basename(path),
      operation: Map.get(args, "operation", "read")
    }
  end

  defp extract_context("terminal", %{"command" => cmd} = args) do
    %{
      file: nil,
      command: cmd,
      type: :terminal,
      tool: "terminal",
      args: args,
      is_test: String.contains?(cmd, ["test", "spec", "pytest"]),
      is_build: String.contains?(cmd, ["build", "compile", "make", "cargo"])
    }
  end

  defp extract_context("code", %{"operation" => op, "path" => path} = args) do
    %{
      file: path,
      command: nil,
      type: :file_op,
      tool: "code",
      args: args,
      operation: op
    }
  end

  # SPEC-090: Web tool context extraction
  defp extract_context("web", %{"query" => query} = args) do
    %{
      file: nil,
      command: nil,
      type: :web_search,
      tool: "web",
      args: args,
      query: query,
      operation: Map.get(args, "operation", "search")
    }
  end

  defp extract_context("web", %{"url" => url} = args) do
    %{
      file: nil,
      command: nil,
      type: :web_fetch,
      tool: "web",
      args: args,
      url: url,
      operation: Map.get(args, "operation", "fetch")
    }
  end

  # SPEC-090: Reason tool context extraction
  defp extract_context("reason", %{"problem" => problem} = args) do
    %{
      file: nil,
      command: nil,
      type: :reasoning,
      tool: "reason",
      args: args,
      problem: problem,
      operation: Map.get(args, "operation", "guided")
    }
  end

  # SPEC-090: Meta tool context extraction
  defp extract_context("meta", %{"query" => query} = args) do
    %{
      file: nil,
      command: nil,
      type: :meta_query,
      tool: "meta",
      args: args,
      query: query,
      operation: Map.get(args, "operation", "prepare_context")
    }
  end

  defp extract_context("meta", %{"task" => task} = args) do
    %{
      file: nil,
      command: nil,
      type: :meta_task,
      tool: "meta",
      args: args,
      task: task,
      operation: Map.get(args, "operation", "suggest_next_tool")
    }
  end

  defp extract_context(tool, args) do
    %{
      file: nil,
      command: nil,
      type: :generic,
      tool: tool,
      args: args
    }
  end

  defp search_related_memories(%{file: path} = context) when is_binary(path) do
    filename = context[:filename] || Path.basename(path)

    # Search for file-specific issues, bugs, patterns
    query = "#{filename} bug issue problem pattern"

    case Memory.search(query, limit: 3, threshold: @inject_threshold) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :file_memory}}
      error -> error
    end
  end

  defp search_related_memories(%{command: cmd, is_test: true}) when is_binary(cmd) do
    # Search for test-related patterns and previous failures
    case Memory.search("test failure pattern flaky", limit: 3, threshold: @inject_threshold) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :test_memory}}
      error -> error
    end
  end

  defp search_related_memories(%{command: cmd, is_build: true}) when is_binary(cmd) do
    # Search for build-related issues
    case Memory.search("build compile error warning", limit: 3, threshold: @inject_threshold) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :build_memory}}
      error -> error
    end
  end

  # SPEC-090: Web search context - find related past searches and learnings
  defp search_related_memories(%{type: :web_search, query: query}) when is_binary(query) do
    # Search for related past research and findings
    case Memory.search(query, limit: 3, threshold: 0.5) do
      {:ok, results} when is_list(results) ->
        {:ok, %{results: results, category: :web_search_memory}}

      error ->
        error
    end
  end

  defp search_related_memories(%{type: :web_fetch, url: url}) when is_binary(url) do
    # Extract domain/path for context search
    query = extract_url_context(url)

    case Memory.search(query, limit: 3, threshold: 0.5) do
      {:ok, results} when is_list(results) ->
        {:ok, %{results: results, category: :web_fetch_memory}}

      _ ->
        empty_result()
    end
  end

  # SPEC-090: Reasoning context - find similar past problems and their solutions
  defp search_related_memories(%{type: :reasoning, problem: problem}) when is_binary(problem) do
    # Use the problem statement to find related past reasoning
    case Memory.search(problem, limit: 5, threshold: 0.4) do
      {:ok, results} when is_list(results) ->
        {:ok, %{results: results, category: :reasoning_memory}}

      error ->
        error
    end
  end

  # SPEC-090: Meta tool context - find related context for the query/task
  defp search_related_memories(%{type: :meta_query, query: query}) when is_binary(query) do
    case Memory.search(query, limit: 3, threshold: 0.5) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :meta_memory}}
      error -> error
    end
  end

  defp search_related_memories(%{type: :meta_task, task: task}) when is_binary(task) do
    case Memory.search(task, limit: 3, threshold: 0.5) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :meta_memory}}
      error -> error
    end
  end

  defp search_related_memories(_context), do: empty_result()

  # SPEC-090: Helper to extract meaningful context from URLs
  defp extract_url_context(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    path = uri.path || ""
    # Combine host and path segments for search
    path_segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))
    Enum.join([host | path_segments], " ")
  rescue
    _ -> url
  end

  defp search_related_patterns(context) do
    # Search for user behavior patterns relevant to this context
    type_str = Atom.to_string(context.type)
    tool_name = context[:tool_name] || type_str

    query = "user pattern preference #{type_str}"

    memory_patterns =
      case Memory.search(query, limit: 2, threshold: @inject_threshold, category: "observation") do
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    # WIRE 4: Check tool chain patterns - what tools commonly follow this one?
    chain_hints = get_tool_chain_hints(tool_name)

    combined_results = memory_patterns ++ chain_hints

    if combined_results == [] do
      empty_result()
    else
      {:ok, %{results: Enum.take(combined_results, 3), category: :pattern}}
    end
  end

  # WIRE 4: Get hints about common tool chains involving this tool
  defp get_tool_chain_hints(tool_name) do
    # Get recent tool sequences to find common patterns
    case Interaction.tool_usage_stats(days: 7) do
      stats when is_map(stats) and map_size(stats) > 0 ->
        # Find tools that are frequently used (top 5)
        frequent_tools =
          stats
          |> Enum.sort_by(fn {_tool, count} -> count end, :desc)
          |> Enum.take(5)
          |> Enum.map(fn {tool, count} -> {tool, count} end)

        # If current tool is frequently used, suggest related patterns
        current_usage = Map.get(stats, tool_name, 0)

        if current_usage > 3 do
          [
            %{
              content:
                "Tool #{tool_name} is frequently used (#{current_usage} times in 7 days). Common tools: #{inspect(Enum.map(frequent_tools, fn {t, _} -> t end))}",
              importance: 0.6,
              category: "pattern"
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp search_related_warnings(%{file: path}) when is_binary(path) do
    filename = Path.basename(path)

    # Search for known issues/warnings related to the file
    query = "warning gap issue #{filename}"

    case Memory.search(query, limit: 2, threshold: @inject_threshold) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :warning}}
      _ -> empty_result()
    end
  end

  defp search_related_warnings(%{command: cmd}) when is_binary(cmd) do
    # Extract command name for more specific search
    cmd_name = cmd |> String.split() |> List.first() |> to_string()

    query = "warning issue #{cmd_name}"

    case Memory.search(query, limit: 2, threshold: @inject_threshold) do
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :warning}}
      _ -> empty_result()
    end
  end

  defp search_related_warnings(_context), do: empty_result()

  defp build_injection(memories, patterns, warnings, context) do
    profile = Map.get(context, :agent_profile, @agent_profiles["default"])
    all_results = collect_results([memories, patterns, warnings], profile)

    if Enum.empty?(all_results) do
      Logger.debug("[PreToolInjector] No relevant knowledge to inject for #{context.tool}")
      nil
    else
      formatted = format_for_injection(all_results)
      scores = Enum.map(all_results, & &1.score)
      # SPEC-065 Enhancement: Include memory IDs for feedback tracking
      memory_ids = Enum.map(all_results, &Map.get(&1, :id)) |> Enum.filter(&(&1 != nil))

      agent_type = Process.get(:mimo_agent_type, "default")

      Logger.debug(
        "[PreToolInjector] Injecting #{length(formatted)} memories for #{context.tool} (agent: #{agent_type})"
      )

      # Generate unique injection ID for feedback correlation
      injection_id = generate_injection_id()

      # Track this injection event for feedback analysis
      track_injection_event(injection_id, memory_ids, context)

      %{
        type: :proactive_injection,
        memories: formatted,
        source: "SPEC-065 Pre-Tool Injection",
        relevance_scores: scores,
        context_type: context.type,
        # New fields for feedback loop
        injection_id: injection_id,
        memory_ids: memory_ids,
        # Agent profile info for debugging
        agent_type: agent_type,
        injection_profile: %{
          max_items: profile.max_items,
          threshold: profile.threshold
        },
        hint: "auto-injected context"
      }
    end
  end

  # Collect and filter results based on agent profile (SPEC-MULTI-AGENT)
  defp collect_results(results, profile) do
    threshold = Map.get(profile, :threshold, @inject_threshold)
    max_items = Map.get(profile, :max_items, @max_injection_items)

    results
    |> Enum.flat_map(fn
      {:ok, r} when is_list(r) -> r
      _ -> []
    end)
    |> Enum.filter(fn r ->
      is_map(r) and Map.has_key?(r, :score) and Map.get(r, :score, 0) >= threshold
    end)
    # SPEC-065 FIX: Deduplicate by content to prevent same memory appearing multiple times
    |> Enum.uniq_by(fn r -> Map.get(r, :content, "") end)
    |> Enum.sort_by(& &1.score, :desc)
    # SPEC-MULTI-AGENT: Use profile max_items instead of module constant
    |> Enum.take(max_items)
  end

  defp format_for_injection(results) do
    Enum.map(results, fn r ->
      content = Map.get(r, :content, "")
      score = Map.get(r, :score, 0.0)

      # Add relevance indicator for high-confidence memories
      prefix = if score >= @high_relevance_threshold, do: "⚡", else: ""

      "#{prefix} #{content}"
    end)
  end

  defp empty_result, do: {:ok, %{results: []}}

  # Generate a unique injection ID for tracking.
  defp generate_injection_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # Track an injection event for later feedback analysis.
  # Uses ETS for lightweight, in-memory tracking.
  defp track_injection_event(injection_id, memory_ids, context) do
    # Store in ETS table for later feedback correlation
    try do
      :ets.insert(:mimo_injection_events, {
        injection_id,
        %{
          memory_ids: memory_ids,
          tool: context.tool,
          context_type: context.type,
          injected_at: DateTime.utc_now(),
          feedback_received: false
        }
      })
    rescue
      ArgumentError ->
        # ETS table doesn't exist yet, create it
        Mimo.EtsSafe.ensure_table(:mimo_injection_events, [:named_table, :public, :set])

        :ets.insert(:mimo_injection_events, {
          injection_id,
          %{
            memory_ids: memory_ids,
            tool: context.tool,
            context_type: context.type,
            injected_at: DateTime.utc_now(),
            feedback_received: false
          }
        })
    end

    :ok
  end

  @doc """
  Record feedback that injected memories were used/referenced.
  This triggers access tracking for the associated memory IDs.

  ## Parameters

    - `injection_id` - The ID from the injection response
    - `feedback_type` - One of: :used, :referenced, :helpful, :ignored

  ## Examples

      PreToolInjector.record_feedback("abc123", :used)
  """
  @spec record_feedback(String.t(), atom()) :: :ok | {:error, :not_found}
  def record_feedback(injection_id, feedback_type)
      when feedback_type in [:used, :referenced, :helpful, :ignored] do
    case :ets.lookup(:mimo_injection_events, injection_id) do
      [{^injection_id, event}] ->
        # Update the event with feedback
        updated_event =
          Map.merge(event, %{
            feedback_received: true,
            feedback_type: feedback_type,
            feedback_at: DateTime.utc_now()
          })

        :ets.insert(:mimo_injection_events, {injection_id, updated_event})

        # If feedback is positive, track access for the memory IDs
        if feedback_type in [:used, :referenced, :helpful] do
          alias Mimo.Brain.AccessTracker
          AccessTracker.track_many(event.memory_ids)

          Logger.debug(
            "[PreToolInjector] Positive feedback for #{length(event.memory_ids)} memories (#{feedback_type})"
          )
        else
          Logger.debug("[PreToolInjector] Negative feedback recorded for injection #{injection_id}")
        end

        :telemetry.execute(
          [:mimo, :injection, :feedback],
          %{count: 1},
          %{
            injection_id: injection_id,
            feedback_type: feedback_type,
            memory_count: length(event.memory_ids)
          }
        )

        :ok

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError ->
      {:error, :not_found}
  end

  @doc """
  Get injection feedback statistics.
  """
  @spec feedback_stats() :: map()
  def feedback_stats do
    try do
      all_events = :ets.tab2list(:mimo_injection_events)

      total = length(all_events)
      with_feedback = Enum.count(all_events, fn {_, e} -> e.feedback_received end)

      feedback_types =
        all_events
        |> Enum.filter(fn {_, e} -> e.feedback_received end)
        |> Enum.group_by(fn {_, e} -> Map.get(e, :feedback_type, :unknown) end)
        |> Enum.map(fn {type, events} -> {type, length(events)} end)
        |> Map.new()

      %{
        total_injections: total,
        with_feedback: with_feedback,
        feedback_rate: if(total > 0, do: Float.round(with_feedback / total * 100, 1), else: 0.0),
        by_type: feedback_types,
        positive_rate: calculate_positive_rate(feedback_types)
      }
    rescue
      ArgumentError ->
        %{status: :no_data, total_injections: 0}
    end
  end

  defp calculate_positive_rate(feedback_types) do
    positive =
      (feedback_types[:used] || 0) + (feedback_types[:referenced] || 0) +
        (feedback_types[:helpful] || 0)

    negative = feedback_types[:ignored] || 0
    total = positive + negative

    if total > 0 do
      Float.round(positive / total * 100, 1)
    else
      0.0
    end
  end
end
