defmodule Mimo.ProceduralStore.AutoGenerator do
  @moduledoc """
  Automatic Procedure Generation from Reasoning Sessions.

  Converts successful reasoning sessions (especially those that led to good
  outcomes) into deterministic procedures that can be executed without
  LLM involvement.

  This is part of the Emergence PoC - proving that agent behaviors can
  be promoted to system capabilities.

  ## Generation Criteria

  A reasoning session is eligible for procedure generation if:
  1. It completed successfully (status == :completed)
  2. It was marked as successful via reason reflect
  3. The steps are deterministic (primarily tool calls)
  4. The pattern has been used successfully multiple times

  ## Process

  1. Analyze reasoning session thoughts/steps
  2. Extract tool calls and their arguments
  3. Build state machine definition
  4. Validate the generated procedure
  5. Register in ProceduralStore

  ## Usage

      # From a completed session
      AutoGenerator.generate_from_session(session_id)

      # From a pattern
      AutoGenerator.generate_from_pattern(pattern_id)
  """

  require Logger

  alias Mimo.Cognitive.ReasoningSession
  alias Mimo.ProceduralStore.Validator

  @doc """
  Generate a procedure from a completed reasoning session.

  Options:
  - :name - Procedure name (default: derived from problem)
  - :version - Version string (default: "1.0")
  - :description - Description (default: from session problem)
  - :auto_register - Whether to register immediately (default: false)
  """
  def generate_from_session(session_id, opts \\ []) do
    case ReasoningSession.get(session_id) do
      {:ok, session} ->
        do_generate(session, opts)

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Generate a procedure from an emergence pattern.

  Looks up associated reasoning sessions for the pattern and generates
  a procedure from the most successful one.
  """
  def generate_from_pattern(pattern_id, _opts \\ []) do
    alias Mimo.Brain.Emergence.UsageTracker

    # Get pattern usage data to find successful sessions
    case UsageTracker.get_impact(pattern_id) do
      {:ok, impact} when impact.success_rate > 0.7 ->
        # find_best_session_for_pattern is not yet implemented
        # When implemented, this will find associated sessions and generate from best one
        find_best_session_for_pattern(pattern_id)

      {:ok, _} ->
        {:error, :pattern_not_successful_enough}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Analyze a session to determine if it's suitable for procedure generation.

  Returns a report with:
  - :suitable - boolean indicating if it can be converted
  - :reasons - list of reasons why/why not
  - :steps_extractable - number of steps that can be automated
  - :suggested_improvements - hints to make it more suitable
  """
  def analyze_suitability(session_id) do
    case ReasoningSession.get(session_id) do
      {:ok, session} ->
        analyze_session_suitability(session)

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  List all reasoning sessions that are good candidates for procedure generation.
  """
  def list_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    _min_success_rate = Keyword.get(opts, :min_success_rate, 0.7)

    # Get completed sessions from ETS
    sessions = ReasoningSession.list_completed()

    # Filter and analyze
    sessions
    |> Enum.filter(fn session ->
      session.status == :completed and
        has_successful_outcome?(session)
    end)
    |> Enum.map(fn session ->
      {:ok, analysis} = analyze_session_suitability(session)
      Map.put(analysis, :session_id, session.id)
    end)
    |> Enum.filter(& &1.suitable)
    |> Enum.sort_by(& &1.steps_extractable, :desc)
    |> Enum.take(limit)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_generate(session, opts) do
    with {:ok, definition} <- build_definition(session),
         :ok <- Validator.validate(definition),
         procedure <- build_procedure(session, definition, opts) do
      if Keyword.get(opts, :auto_register, false) do
        register_procedure(procedure)
      else
        {:ok, procedure}
      end
    end
  end

  defp build_definition(session) do
    steps = extract_tool_steps(session.thoughts)

    if length(steps) < 2 do
      {:error, :too_few_steps}
    else
      definition = %{
        "states" => build_states(steps),
        "initial" => "start",
        "final" => ["success", "failure"],
        "context_schema" => build_context_schema(steps)
      }

      {:ok, definition}
    end
  end

  defp extract_tool_steps(thoughts) do
    thoughts
    |> Enum.filter(&tool_call?/1)
    |> Enum.map(&parse_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_call?(thought) do
    content = thought.content || ""

    # Look for common tool call patterns in thought content
    String.contains?(content, "operation=") or
      String.contains?(content, "file operation") or
      String.contains?(content, "terminal command") or
      String.contains?(content, "code operation")
  end

  defp parse_tool_call(thought) do
    content = thought.content || ""

    # Try to extract tool and operation from thought content
    cond do
      String.contains?(content, "file operation=") ->
        extract_operation(content, "file")

      String.contains?(content, "terminal command=") ->
        %{tool: "terminal", operation: "execute", extracted_from: content}

      String.contains?(content, "code operation=") ->
        extract_operation(content, "code")

      String.contains?(content, "web operation=") ->
        extract_operation(content, "web")

      String.contains?(content, "memory operation=") ->
        extract_operation(content, "memory")

      true ->
        nil
    end
  end

  defp extract_operation(content, tool) do
    # Simple regex to extract operation name
    case Regex.run(~r/operation=(\w+)/, content) do
      [_, operation] ->
        %{tool: tool, operation: operation, extracted_from: content}

      _ ->
        %{tool: tool, operation: "default", extracted_from: content}
    end
  end

  defp build_states(steps) do
    # Build a linear state machine from steps
    indexed_steps = Enum.with_index(steps)

    states =
      Enum.reduce(indexed_steps, %{}, fn {step, index}, acc ->
        state_name = "step_#{index}"
        next_state = if index < length(steps) - 1, do: "step_#{index + 1}", else: "success"

        state_def = %{
          "action" => %{
            "type" => "tool_call",
            "tool" => step.tool,
            "operation" => step.operation,
            "arguments" => "${context}"
          },
          "transitions" => [
            %{"on" => "success", "to" => next_state},
            %{"on" => "error", "to" => "failure"}
          ]
        }

        Map.put(acc, state_name, state_def)
      end)

    # Add start, success, and failure states
    states
    |> Map.put("start", %{
      "action" => %{"type" => "noop"},
      "transitions" => [%{"on" => "continue", "to" => "step_0"}]
    })
    |> Map.put("success", %{
      "action" => %{"type" => "complete", "status" => "success"}
    })
    |> Map.put("failure", %{
      "action" => %{"type" => "complete", "status" => "failure"}
    })
  end

  defp build_context_schema(steps) do
    # Build a minimal context schema from the steps
    tools_used = steps |> Enum.map(& &1.tool) |> Enum.uniq()

    %{
      "type" => "object",
      "description" => "Context for auto-generated procedure",
      "required" => [],
      "properties" => build_schema_properties(tools_used)
    }
  end

  defp build_schema_properties(tools) do
    base = %{
      "target_path" => %{"type" => "string", "description" => "Target path for file operations"},
      "command" => %{"type" => "string", "description" => "Command for terminal operations"}
    }

    if "web" in tools do
      Map.put(base, "url", %{"type" => "string", "description" => "URL for web operations"})
    else
      base
    end
  end

  defp build_procedure(session, definition, opts) do
    name = Keyword.get(opts, :name) || generate_name(session)
    version = Keyword.get(opts, :version, "1.0")
    description = Keyword.get(opts, :description) || session.problem

    %{
      name: name,
      version: version,
      description: description,
      definition: definition,
      metadata: %{
        source: "auto_generated",
        source_session_id: session.id,
        source_strategy: session.strategy,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp generate_name(session) do
    # Generate a name from the problem description
    session.problem
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(4)
    |> Enum.join("_")
    |> then(fn name ->
      if String.length(name) < 3,
        do: "auto_procedure_#{System.unique_integer([:positive])}",
        else: name
    end)
  end

  defp register_procedure(procedure) do
    alias Mimo.ProceduralStore.Loader

    case Loader.register(procedure) do
      {:ok, registered} ->
        Logger.info("✅ Auto-generated procedure registered: #{procedure.name}")
        {:ok, registered}

      {:error, reason} ->
        Logger.warning("⚠️ Failed to register auto-generated procedure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp analyze_session_suitability(session) do
    steps = extract_tool_steps(session.thoughts)
    total_thoughts = length(session.thoughts)

    extractable_ratio = if total_thoughts > 0, do: length(steps) / total_thoughts, else: 0

    reasons = []

    reasons =
      if session.status != :completed, do: ["Session not completed" | reasons], else: reasons

    reasons = if length(steps) < 2, do: ["Too few extractable steps" | reasons], else: reasons

    reasons =
      if extractable_ratio < 0.3, do: ["Low extractable step ratio" | reasons], else: reasons

    suitable = session.status == :completed and length(steps) >= 2 and extractable_ratio >= 0.3

    {:ok,
     %{
       suitable: suitable,
       reasons: reasons,
       steps_extractable: length(steps),
       total_thoughts: total_thoughts,
       extractable_ratio: Float.round(extractable_ratio, 2),
       strategy: session.strategy,
       suggested_improvements: if(suitable, do: [], else: suggest_improvements(reasons))
     }}
  end

  defp suggest_improvements(reasons) do
    Enum.flat_map(reasons, fn reason ->
      case reason do
        "Session not completed" ->
          ["Complete the reasoning session (reason: conclude)"]

        "Too few extractable steps" ->
          ["Add more tool-based steps to the reasoning"]

        "Low extractable step ratio" ->
          ["Focus on concrete tool operations rather than abstract reasoning"]

        _ ->
          []
      end
    end)
  end

  defp has_successful_outcome?(session) do
    # Check if session has successful reflection stored
    # This is a heuristic - in practice we'd check the stored reflection
    session.status == :completed
  end

  defp find_best_session_for_pattern(_pattern_id) do
    # In a full implementation, this would look up sessions associated
    # with the pattern and return the most successful one.
    # For now, return an error as we need more infrastructure.
    {:error, :not_implemented}
  end
end
