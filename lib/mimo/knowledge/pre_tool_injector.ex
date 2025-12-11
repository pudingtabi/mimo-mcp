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

  alias Mimo.Brain.Memory

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

  # ============================================================================
  # PUBLIC API
  # ============================================================================

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

      # Await with timeout to avoid blocking tool execution too long
      results =
        try do
          Task.await_many(tasks, @parallel_timeout_ms)
        catch
          :exit, _ ->
            Logger.debug("[PreToolInjector] Parallel search timeout, using empty results")
            Enum.map(tasks, fn _ -> empty_result() end)
        end

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
  defp unpack_search_results(results, profile) do
    case {profile.include_patterns, profile.include_warnings} do
      {true, true} ->
        # All three: [memories, patterns, warnings]
        case results do
          [m, p, w] -> {m, p, w}
          _ -> {empty_result(), empty_result(), empty_result()}
        end

      {true, false} ->
        # Only memories and patterns
        case results do
          [m, p] -> {m, p, empty_result()}
          [m] -> {m, empty_result(), empty_result()}
          _ -> {empty_result(), empty_result(), empty_result()}
        end

      {false, true} ->
        # Only memories and warnings
        case results do
          [m, w] -> {m, empty_result(), w}
          [m] -> {m, empty_result(), empty_result()}
          _ -> {empty_result(), empty_result(), empty_result()}
        end

      {false, false} ->
        # Only memories
        case results do
          [m] -> {m, empty_result(), empty_result()}
          _ -> {empty_result(), empty_result(), empty_result()}
        end
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

  # ============================================================================
  # CONTEXT EXTRACTION
  # ============================================================================

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

  defp extract_context(tool, args) do
    %{
      file: nil,
      command: nil,
      type: :generic,
      tool: tool,
      args: args
    }
  end

  # ============================================================================
  # MEMORY SEARCH FUNCTIONS
  # ============================================================================

  defp search_related_memories(%{file: path} = context) when is_binary(path) do
    filename = context[:filename] || Path.basename(path)

    # Search for file-specific issues, bugs, patterns
    query = "#{filename} bug issue problem pattern"

    case Memory.search(query, limit: 3, threshold: @inject_threshold) do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :file_memory}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :file_memory}}
      error -> error
    end
  end

  defp search_related_memories(%{command: cmd, is_test: true}) when is_binary(cmd) do
    # Search for test-related patterns and previous failures
    case Memory.search("test failure pattern flaky", limit: 3, threshold: @inject_threshold) do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :test_memory}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :test_memory}}
      error -> error
    end
  end

  defp search_related_memories(%{command: cmd, is_build: true}) when is_binary(cmd) do
    # Search for build-related issues
    case Memory.search("build compile error warning", limit: 3, threshold: @inject_threshold) do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :build_memory}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :build_memory}}
      error -> error
    end
  end

  defp search_related_memories(_context), do: empty_result()

  defp search_related_patterns(context) do
    # Search for user behavior patterns relevant to this context
    type_str = Atom.to_string(context.type)

    query = "user pattern preference #{type_str}"

    case Memory.search(query, limit: 2, threshold: @inject_threshold, category: "observation") do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :pattern}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :pattern}}
      _ -> empty_result()
    end
  end

  defp search_related_warnings(%{file: path}) when is_binary(path) do
    filename = Path.basename(path)

    # Search for known issues/warnings related to the file
    query = "warning gap issue #{filename}"

    case Memory.search(query, limit: 2, threshold: @inject_threshold) do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :warning}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :warning}}
      _ -> empty_result()
    end
  end

  defp search_related_warnings(%{command: cmd}) when is_binary(cmd) do
    # Extract command name for more specific search
    cmd_name = cmd |> String.split() |> List.first() |> to_string()

    query = "warning issue #{cmd_name}"

    case Memory.search(query, limit: 2, threshold: @inject_threshold) do
      {:ok, %{results: results}} -> {:ok, %{results: results, category: :warning}}
      {:ok, results} when is_list(results) -> {:ok, %{results: results, category: :warning}}
      _ -> empty_result()
    end
  end

  defp search_related_warnings(_context), do: empty_result()

  # ============================================================================
  # INJECTION BUILDING
  # ============================================================================

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
        hint: "💡 Mimo surfaced this knowledge proactively based on your action"
      }
    end
  end

  # Collect and filter results based on agent profile (SPEC-MULTI-AGENT)
  defp collect_results(results, profile) do
    threshold = Map.get(profile, :threshold, @inject_threshold)
    max_items = Map.get(profile, :max_items, @max_injection_items)

    results
    |> Enum.flat_map(fn
      {:ok, %{results: r}} when is_list(r) -> r
      {:ok, r} when is_list(r) -> r
      _ -> []
    end)
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&Map.has_key?(&1, :score))
    # SPEC-MULTI-AGENT: Filter by profile threshold
    |> Enum.filter(fn r -> Map.get(r, :score, 0) >= threshold end)
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
      prefix = if score >= @high_relevance_threshold, do: "⚡", else: "💡"

      "#{prefix} #{content}"
    end)
  end

  defp empty_result, do: {:ok, %{results: []}}

  # ============================================================================
  # INJECTION FEEDBACK TRACKING (SPEC-065 Enhancement)
  # ============================================================================

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
        :ets.new(:mimo_injection_events, [:named_table, :public, :set])

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
