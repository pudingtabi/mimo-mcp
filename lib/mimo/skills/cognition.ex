defmodule Mimo.Skills.Cognition do
  @moduledoc """
  Cognitive functions for LLM reasoning.

  Provides:
  - Think: Record individual thoughts
  - Plan: Record multi-step plans
  - Sequential Thinking: Dynamic problem-solving through structured thought sequences

  Native replacement for sequential_thinking MCP server.
  """
  require Logger
  use Agent

  defmodule ThinkingState do
    @moduledoc false
    defstruct sessions: %{}, current_session: nil
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %ThinkingState{} end, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  # Thinking Templates - Domain-specific guided thinking patterns

  @thinking_templates %{
    debug: """
    1. SYMPTOMS: What exactly is happening vs expected?
    2. CONTEXT: When did it start? What changed recently?
    3. HYPOTHESES: List 3 possible causes (most likely first)
    4. VERIFICATION: How to test each hypothesis?
    5. EVIDENCE: What do logs/errors/state tell us?
    6. ROOT CAUSE: Based on evidence, what's the real issue?
    7. FIX: What's the minimal change to resolve this?
    """,
    implement: """
    1. REQUIREMENTS: What exactly needs to be built?
    2. CONTEXT: What existing code/patterns can I reuse?
    3. APPROACH: What's the simplest implementation that works?
    4. DEPENDENCIES: What modules/functions does this need?
    5. EDGE CASES: What could go wrong? How to handle?
    6. TESTS: How will I verify this works?
    7. INTEGRATION: How does this fit with existing code?
    """,
    refactor: """
    1. CURRENT STATE: What's the existing code doing?
    2. PROBLEMS: What's wrong with it (complexity, bugs, performance)?
    3. GOAL: What should it look like after?
    4. APPROACH: Incremental or big-bang refactor?
    5. SAFETY: How to ensure behavior doesn't change?
    6. STEPS: What's the sequence of changes?
    7. VALIDATION: How to verify the refactor is complete?
    """,
    tool_decision: """
    1. GOAL: What am I trying to accomplish?
    2. CONTEXT: What do I already know from memory?
    3. OPTIONS: What tools could help here?
    4. TRADEOFFS: Which tool is most efficient?
    5. SEQUENCE: What order should I use tools?
    6. FALLBACK: What if the chosen tool fails?
    """,
    error_analysis: """
    1. ERROR MESSAGE: What exactly does it say?
    2. LOCATION: Where in the code does it occur?
    3. TYPE: Compile error, runtime error, logic error?
    4. SIMILAR: Have I seen this error pattern before?
    5. CAUSE: What triggered this specific error?
    6. FIX: What's the correct code change?
    7. PREVENTION: How to avoid this in future?
    """
  }

  @doc """
  Get a thinking template for a specific scenario.

  Templates guide structured reasoning for common tasks,
  implementing Anthropic's Think Tool best practice of
  providing domain-specific thinking examples.

  ## Available Templates

  - `:debug` - Debugging workflow
  - `:implement` - Feature implementation
  - `:refactor` - Code refactoring
  - `:tool_decision` - Choosing which tools to use
  - `:error_analysis` - Analyzing error messages

  ## Example

      {:ok, template} = Cognition.get_template(:debug)
  """
  @spec get_template(atom()) :: {:ok, String.t()} | {:error, String.t()}
  def get_template(scenario) when is_atom(scenario) do
    case Map.get(@thinking_templates, scenario) do
      nil ->
        {:error,
         "Unknown template: #{scenario}. Available: #{@thinking_templates |> Map.keys() |> Enum.join(", ")}"}

      template ->
        {:ok, String.trim(template)}
    end
  end

  @doc """
  Think with template guidance.

  Combines the thought with a structured template for the scenario,
  guiding more systematic reasoning.
  """
  @spec think_with_template(String.t(), atom()) :: {:ok, map()} | {:error, String.t()}
  def think_with_template(thought, scenario) do
    case get_template(scenario) do
      {:ok, template} ->
        guided_thought = """
        ## Thinking Framework (#{scenario})
        #{template}

        ## Current Thought
        #{thought}
        """

        Logger.info("[THINK:#{scenario}] #{thought}")

        {:ok,
         %{
           status: "recorded",
           thought: guided_thought,
           scenario: scenario,
           template: template,
           raw_thought: thought,
           timestamp: DateTime.utc_now()
         }}

      error ->
        error
    end
  end

  @doc """
  List all available thinking templates.
  """
  @spec list_templates() :: {:ok, [atom()]}
  def list_templates do
    {:ok, Map.keys(@thinking_templates)}
  end

  def think(thought) do
    Logger.info("[THINK] #{thought}")
    {:ok, %{status: "recorded", thought: thought, timestamp: DateTime.utc_now()}}
  end

  def plan(steps) when is_list(steps) do
    Logger.info("[PLAN] #{length(steps)} steps recorded")

    formatted_steps =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, idx} -> "#{idx}. #{step}" end)

    {:ok, %{status: "recorded", steps: steps, formatted: formatted_steps}}
  end

  def plan(steps) when is_binary(steps) do
    plan([steps])
  end

  @doc """
  Record a sequential thought as part of a structured problem-solving process.

  ## Parameters
  - thought: The content of this thought step
  - thought_number: Current step number (1-indexed)
  - total_thoughts: Expected total number of thoughts
  - next_thought_needed: Whether more thoughts are needed after this

  ## Returns
  - {:ok, %{...}} with session info and whether to continue
  """
  def sequential_thinking(params) when is_map(params) do
    ensure_started()

    thought = Map.get(params, "thought") || Map.get(params, :thought, "")
    thought_number = Map.get(params, "thoughtNumber") || Map.get(params, :thought_number, 1)
    total_thoughts = Map.get(params, "totalThoughts") || Map.get(params, :total_thoughts, 1)

    next_needed =
      Map.get(params, "nextThoughtNeeded") || Map.get(params, :next_thought_needed, false)

    session_id = get_or_create_session()

    thought_record = %{
      number: thought_number,
      content: thought,
      timestamp: DateTime.utc_now()
    }

    # Update session with new thought
    Agent.update(__MODULE__, fn state ->
      session = Map.get(state.sessions, session_id, %{thoughts: [], total: total_thoughts})

      updated_session = %{
        session
        | thoughts: session.thoughts ++ [thought_record],
          total: total_thoughts
      }

      %{state | sessions: Map.put(state.sessions, session_id, updated_session)}
    end)

    # Log for visibility
    Logger.info(
      "[SEQUENTIAL_THINKING] Step #{thought_number}/#{total_thoughts}: #{String.slice(thought, 0, 100)}..."
    )

    # Get session summary
    session_data =
      Agent.get(__MODULE__, fn state ->
        Map.get(state.sessions, session_id, %{thoughts: [], total: total_thoughts})
      end)

    progress = thought_number / max(total_thoughts, 1) * 100

    {:ok,
     %{
       session_id: session_id,
       thought_number: thought_number,
       total_thoughts: total_thoughts,
       progress_percent: Float.round(progress, 1),
       thoughts_recorded: length(session_data.thoughts),
       next_thought_needed: next_needed,
       status: if(next_needed, do: "continue", else: "complete")
     }}
  end

  @doc """
  Get the current thinking session's thoughts.
  """
  def get_session_thoughts(session_id \\ nil) do
    ensure_started()

    sid = session_id || Agent.get(__MODULE__, fn state -> state.current_session end)

    if sid do
      session =
        Agent.get(__MODULE__, fn state ->
          Map.get(state.sessions, sid, %{thoughts: [], total: 0})
        end)

      {:ok,
       %{
         session_id: sid,
         thoughts: session.thoughts,
         total_expected: session.total,
         total_recorded: length(session.thoughts)
       }}
    else
      {:error, "No active thinking session"}
    end
  end

  @doc """
  Clear the current thinking session and start fresh.
  """
  def reset_session do
    ensure_started()

    new_session_id = generate_session_id()

    Agent.update(__MODULE__, fn state ->
      %{state | current_session: new_session_id}
    end)

    {:ok, %{session_id: new_session_id, status: "new_session_started"}}
  end

  @doc """
  Get summary of all thinking sessions.
  """
  def list_sessions do
    ensure_started()

    sessions =
      Agent.get(__MODULE__, fn state ->
        Enum.map(state.sessions, fn {id, data} ->
          %{
            session_id: id,
            thought_count: length(data.thoughts),
            expected_total: data.total,
            first_thought: List.first(data.thoughts),
            last_thought: List.last(data.thoughts)
          }
        end)
      end)

    current = Agent.get(__MODULE__, fn state -> state.current_session end)

    {:ok, %{sessions: sessions, current_session: current, total_sessions: length(sessions)}}
  end

  defp get_or_create_session do
    current = Agent.get(__MODULE__, fn state -> state.current_session end)

    if current do
      current
    else
      new_id = generate_session_id()

      Agent.update(__MODULE__, fn state ->
        %{
          state
          | current_session: new_id,
            sessions: Map.put(state.sessions, new_id, %{thoughts: [], total: 0})
        }
      end)

      new_id
    end
  end

  defp generate_session_id do
    "thinking_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(9999)}"
  end
end
