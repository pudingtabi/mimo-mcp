defmodule Mimo.Cognitive.Strategies.ReActStrategy do
  @moduledoc """
  ReAct (Reasoning + Acting) strategy.

  Interleaves thinking and tool use:
  - Thought → Action → Observation → Thought...
  - Integrates with all Mimo tools
  - Tracks action results for reasoning

  ## Reference

  Yao et al. (2022) - "ReAct: Synergizing Reasoning and Acting
  in Language Models"

  ## Best For

  - Debugging and troubleshooting
  - Tasks requiring external information
  - Problems needing file/code inspection
  - Multi-step tool-use scenarios
  """

  alias Mimo.Cognitive.ThoughtEvaluator

  @type step_type :: :thought | :action | :observation
  @type trajectory_step :: %{
          type: step_type(),
          content: String.t(),
          timestamp: DateTime.t(),
          tool: String.t() | nil,
          tool_args: map() | nil
        }

  @type react_step :: %{
          type: step_type(),
          content: String.t(),
          suggested_tool: String.t() | nil,
          tool_args: map() | nil,
          rationale: String.t()
        }

  @type action_suggestion :: %{
          tool: String.t(),
          operation: String.t() | nil,
          args: map(),
          rationale: String.t()
        }

  # Tool patterns for suggesting appropriate tools
  @tool_patterns [
    {~r/\b(read|view|look at|check|examine)\s+(?:the\s+)?(?:file|code|content)/i, "file", "read"},
    {~r/\b(search|find|look for|grep)\s+(?:for\s+)?/i, "file", "search"},
    {~r/\b(list|show)\s+(?:the\s+)?(?:files|directory|contents)/i, "file", "list_directory"},
    {~r/\b(run|execute|test|compile)\b/i, "terminal", "execute"},
    {~r/\b(search|look up|google|find)\s+(?:for\s+)?(?:docs|documentation|info)/i, "search", "web"},
    {~r/\b(fetch|get|retrieve)\s+(?:the\s+)?(?:url|page|site)/i, "fetch", nil},
    {~r/\b(find|locate)\s+(?:the\s+)?(?:function|class|method|definition)/i, "code_symbols",
     "definition"},
    {~r/\b(what|where)\s+(?:is|does|are)\s+(?:the\s+)?(?:import|depend)/i, "code_symbols",
     "references"},
    {~r/\b(check|get)\s+(?:the\s+)?(?:errors|warnings|diagnostics)/i, "diagnostics", "all"},
    {~r/\b(documentation|docs)\s+(?:for|of)\s+(\w+)/i, "library", "get"}
  ]

  @doc """
  Generate the next ReAct step based on trajectory.

  ## Parameters

  - `problem` - The original problem statement
  - `trajectory` - List of previous steps (thought/action/observation)
  - `opts` - Options:
    - `:max_steps` - Maximum steps before forcing conclusion
  """
  @spec generate_step(String.t(), [trajectory_step()], keyword()) :: react_step()
  def generate_step(problem, trajectory, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, 10)

    cond do
      # No trajectory yet - start with a thought
      trajectory == [] ->
        %{
          type: :thought,
          content: "I need to understand the problem and plan my approach.",
          suggested_tool: nil,
          tool_args: nil,
          rationale: "Starting fresh - need to analyze the problem first"
        }

      # After observation - generate thought to process it
      last_step_type(trajectory) == :observation ->
        observation = get_last_step(trajectory)

        %{
          type: :thought,
          content: "Based on the observation, I can see that...",
          suggested_tool: nil,
          tool_args: nil,
          rationale: "Processing observation: #{String.slice(observation.content, 0..100)}"
        }

      # After thought - suggest action if applicable
      last_step_type(trajectory) == :thought ->
        thought = get_last_step(trajectory)
        action = suggest_action(thought.content, problem)

        if action && length(trajectory) < max_steps do
          %{
            type: :action,
            content: "Using #{action.tool} to #{action.rationale}",
            suggested_tool: action.tool,
            tool_args: action.args,
            rationale: action.rationale
          }
        else
          %{
            type: :thought,
            content: "Let me continue reasoning about this...",
            suggested_tool: nil,
            tool_args: nil,
            rationale: "No specific tool action needed"
          }
        end

      # After action - expect observation
      last_step_type(trajectory) == :action ->
        %{
          type: :observation,
          content: "[Waiting for action result]",
          suggested_tool: nil,
          tool_args: nil,
          rationale: "Processing action result"
        }

      # Default
      true ->
        %{
          type: :thought,
          content: "Continuing analysis...",
          suggested_tool: nil,
          tool_args: nil,
          rationale: "Default continuation"
        }
    end
  end

  @doc """
  Suggest an appropriate Mimo tool based on thought content.
  """
  @spec suggest_action(String.t(), String.t()) :: action_suggestion() | nil
  def suggest_action(thought, problem) do
    thought_lower = String.downcase(thought)
    problem_lower = String.downcase(problem)
    combined = thought_lower <> " " <> problem_lower

    # Check patterns for tool suggestions
    Enum.find_value(@tool_patterns, fn {pattern, tool, operation} ->
      if String.match?(combined, pattern) do
        args = extract_tool_args(combined, tool, operation)

        %{
          tool: tool,
          operation: operation,
          args: args,
          rationale: generate_action_rationale(tool, operation)
        }
      end
    end)
  end

  @doc """
  Process an observation and add it to the trajectory.
  """
  @spec process_observation(term(), [trajectory_step()]) :: trajectory_step()
  def process_observation(action_result, _trajectory) do
    content = format_observation(action_result)

    %{
      type: :observation,
      content: content,
      timestamp: DateTime.utc_now(),
      tool: nil,
      tool_args: nil
    }
  end

  @doc """
  Check if the goal has been reached.
  """
  @spec goal_reached?([trajectory_step()], String.t()) :: boolean()
  def goal_reached?(trajectory, problem) do
    if length(trajectory) < 3 do
      false
    else
      # Check recent thoughts for completion indicators
      recent_thoughts =
        trajectory
        |> Enum.filter(&(&1.type == :thought))
        |> Enum.take(-3)
        |> Enum.map_join(" ", & &1.content)

      completion_patterns = [
        ~r/\b(found|solved|fixed|completed|done|answer is|solution is)\b/i,
        ~r/\b(successfully|successfully)\s+(fixed|resolved|found|completed)\b/i,
        ~r/\b(problem|issue|bug)\s+(is\s+)?(fixed|resolved|solved)\b/i,
        ~r/\b(this (works|solves|fixes))\b/i
      ]

      # Also check if the problem keywords appear with success indicators
      problem_words = extract_key_words(problem)

      Enum.any?(completion_patterns, &String.match?(recent_thoughts, &1)) or
        (problem_words != [] and
           Enum.any?(problem_words, &String.contains?(String.downcase(recent_thoughts), &1)) and
           String.match?(recent_thoughts, ~r/\b(done|complete|finished|solved)\b/i))
    end
  end

  @doc """
  Get suggested next actions based on current state.
  """
  @spec get_available_actions(String.t(), [trajectory_step()]) :: [action_suggestion()]
  def get_available_actions(problem, trajectory) do
    problem_lower = String.downcase(problem)

    # Generate context-appropriate suggestions
    suggestions = []

    # File-related suggestions
    suggestions =
      if String.match?(problem_lower, ~r/\b(file|code|source|module|function)\b/) do
        [
          %{tool: "file", operation: "read", args: %{}, rationale: "Read relevant source files"},
          %{tool: "code_symbols", operation: "symbols", args: %{}, rationale: "List code symbols"},
          %{tool: "file", operation: "search", args: %{}, rationale: "Search for patterns in code"}
          | suggestions
        ]
      else
        suggestions
      end

    # Error-related suggestions
    suggestions =
      if String.match?(problem_lower, ~r/\b(error|bug|fail|broken|issue)\b/) do
        [
          %{
            tool: "diagnostics",
            operation: "all",
            args: %{},
            rationale: "Check for compile/lint errors"
          },
          %{tool: "terminal", operation: "execute", args: %{}, rationale: "Run tests"},
          %{
            tool: "file",
            operation: "search",
            args: %{pattern: "TODO|FIXME|BUG"},
            rationale: "Find marked issues"
          }
          | suggestions
        ]
      else
        suggestions
      end

    # Research suggestions
    suggestions =
      if String.match?(problem_lower, ~r/\b(how|what|why|documentation|example)\b/) do
        [
          %{tool: "search", operation: "web", args: %{}, rationale: "Search for documentation"},
          %{tool: "library", operation: "get", args: %{}, rationale: "Get package documentation"}
          | suggestions
        ]
      else
        suggestions
      end

    # Remove actions already taken in trajectory
    taken_tools =
      trajectory
      |> Enum.filter(&(&1.type == :action and &1.tool))
      |> Enum.map(&{&1.tool, &1.tool_args})

    Enum.reject(suggestions, fn s ->
      Enum.any?(taken_tools, fn {tool, _} -> tool == s.tool end)
    end)
  end

  @doc """
  Format trajectory for display.
  """
  @spec format_trajectory([trajectory_step()]) :: String.t()
  def format_trajectory(trajectory) do
    trajectory
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {step, idx} ->
      type_label = step.type |> to_string() |> String.capitalize()
      tool_info = if step.tool, do: " (#{step.tool})", else: ""
      "**#{type_label} #{idx}#{tool_info}:** #{step.content}"
    end)
  end

  @doc """
  Evaluate the trajectory quality.
  """
  @spec evaluate_trajectory([trajectory_step()], String.t()) :: map()
  def evaluate_trajectory(trajectory, problem) do
    thoughts = Enum.filter(trajectory, &(&1.type == :thought))
    actions = Enum.filter(trajectory, &(&1.type == :action))
    observations = Enum.filter(trajectory, &(&1.type == :observation))

    # Evaluate thought quality
    thought_scores =
      Enum.map(thoughts, fn t ->
        eval = ThoughtEvaluator.evaluate(t.content, %{problem: problem})
        eval.score
      end)

    avg_thought_score =
      if thought_scores == [], do: 0.0, else: Enum.sum(thought_scores) / length(thought_scores)

    # Check action effectiveness
    action_count = length(actions)
    observation_count = length(observations)
    action_success_rate = if action_count > 0, do: observation_count / action_count, else: 1.0

    %{
      total_steps: length(trajectory),
      thoughts: length(thoughts),
      actions: action_count,
      observations: observation_count,
      average_thought_quality: Float.round(avg_thought_score, 3),
      action_success_rate: Float.round(action_success_rate, 3),
      goal_reached: goal_reached?(trajectory, problem)
    }
  end

  # Private helpers

  defp last_step_type(trajectory) do
    case List.last(trajectory) do
      nil -> nil
      step -> step.type
    end
  end

  defp get_last_step(trajectory) do
    List.last(trajectory)
  end

  defp extract_tool_args(text, tool, operation) do
    base_args = if operation, do: %{"operation" => operation}, else: %{}

    case tool do
      "file" ->
        # Try to extract file path
        path = extract_file_path(text)
        if path, do: Map.put(base_args, "path", path), else: base_args

      "terminal" ->
        # Try to extract command
        cmd = extract_command(text)
        if cmd, do: Map.put(base_args, "command", cmd), else: base_args

      "search" ->
        # Try to extract search query
        query = extract_search_query(text)
        if query, do: Map.put(base_args, "query", query), else: base_args

      "code_symbols" ->
        # Try to extract symbol name
        name = extract_symbol_name(text)
        if name, do: Map.put(base_args, "name", name), else: base_args

      "library" ->
        # Try to extract package name
        pkg = extract_package_name(text)
        if pkg, do: Map.put(base_args, "name", pkg), else: base_args

      _ ->
        base_args
    end
  end

  defp extract_file_path(text) do
    case Regex.run(~r/(?:file|path)[\s:]+["']?([\/\w\.\-_]+)["']?/i, text) do
      [_, path] ->
        path

      _ ->
        case Regex.run(~r/\b([\w\/]+\.(?:ex|exs|ts|js|py|rb|rs|go))\b/, text) do
          [_, path] -> path
          _ -> nil
        end
    end
  end

  defp extract_command(text) do
    case Regex.run(~r/(?:run|execute|command)[\s:]+["']?(.+?)["']?(?:\s|$)/i, text) do
      [_, cmd] -> String.trim(cmd)
      _ -> nil
    end
  end

  defp extract_search_query(text) do
    case Regex.run(~r/(?:search|look for|find)[\s:]+["']?(.+?)["']?(?:\s|$)/i, text) do
      [_, query] -> String.trim(query)
      _ -> nil
    end
  end

  defp extract_symbol_name(text) do
    case Regex.run(~r/(?:function|class|method|module)\s+["']?(\w+)["']?/i, text) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp extract_package_name(text) do
    case Regex.run(~r/(?:docs?|documentation|package|library)\s+(?:for\s+)?["']?(\w+)["']?/i, text) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp generate_action_rationale(tool, operation) do
    case {tool, operation} do
      {"file", "read"} -> "examine the relevant file content"
      {"file", "search"} -> "search for relevant patterns or code"
      {"file", "list_directory"} -> "see the project structure"
      {"terminal", _} -> "execute a command to test or verify"
      {"search", _} -> "find external information or documentation"
      {"fetch", _} -> "retrieve web content"
      {"code_symbols", "definition"} -> "locate the code definition"
      {"code_symbols", "references"} -> "find all usages"
      {"diagnostics", _} -> "check for errors and warnings"
      {"library", _} -> "look up package documentation"
      _ -> "gather more information"
    end
  end

  defp format_observation(result) do
    case result do
      {:ok, data} when is_map(data) ->
        # Format map data nicely
        data
        |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{inspect(v, limit: 100)}" end)
        |> String.slice(0..1000)

      {:ok, data} when is_binary(data) ->
        String.slice(data, 0..1000)

      {:error, reason} ->
        "Error: #{inspect(reason)}"

      data when is_binary(data) ->
        String.slice(data, 0..1000)

      data ->
        inspect(data, limit: 50) |> String.slice(0..1000)
    end
  end

  defp extract_key_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(5)
  end
end
