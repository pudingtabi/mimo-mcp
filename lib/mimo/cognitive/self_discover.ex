defmodule Mimo.Cognitive.SelfDiscover do
  @moduledoc """
  SPEC-063: SELF-DISCOVER - Self-compose reasoning structures for complex tasks.

  Based on Google DeepMind research (arXiv 2402.03620):
  - 32% improvement over Chain-of-Thought on BigBench-Hard
  - 10-40x more efficient than self-consistency
  - Structures transfer across models (PaLM → GPT-4 → Llama2)

  ## Method

  1. **SELECT**: Choose relevant reasoning modules from 39 atomic modules
  2. **ADAPT**: Tailor modules to specific task
  3. **IMPLEMENT**: Create JSON reasoning structure
  4. **SOLVE**: Follow structure to answer

  ## Usage

      # Discover task-specific reasoning structure
      {:ok, structure} = SelfDiscover.discover("I'm going to ask you 5 trivia questions...")

      # Use structure to solve
      {:ok, answer} = SelfDiscover.solve(task, structure.reasoning_structure)
  """

  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Cognitive.ReasoningTelemetry

  # ============================================================================
  # 39 ATOMIC REASONING MODULES (from Google DeepMind paper)
  # ============================================================================

  @atomic_modules [
    # Problem decomposition (1-10)
    "How can I break down this problem into smaller, more manageable parts?",
    "What are the key assumptions underlying this problem?",
    "How could I devise an experiment to help solve that problem?",
    "Make a list of ideas for solving this problem, and apply them one by one",
    "How could I measure progress on this problem?",
    "How can I simplify the problem so that it is easier to solve?",
    "What is the core issue or problem that needs to be addressed?",
    "What are the potential obstacles or challenges that might arise?",
    "Are there any relevant data or information that can provide insights?",
    "Does this problem require generating sub-problems or sub-tasks?",
    # Critical thinking (11-20)
    "Critical Thinking: analyze from different perspectives, question assumptions",
    "What are the potential risks and drawbacks of each solution?",
    "What are the alternative viewpoints or perspectives on this problem?",
    "What are the long-term implications of this decision or action?",
    "How can I verify the accuracy or validity of this information?",
    "What biases or assumptions might be influencing my thinking?",
    "What is the relationship between the different components of the problem?",
    "What are the underlying causes or factors contributing to the problem?",
    "What are the potential consequences of not addressing this problem?",
    "Is there implicit information that needs to be made explicit?",
    # Creative thinking (21-30)
    "Try creative thinking, generate innovative and out-of-the-box ideas",
    "What kinds of solution typically are produced for this kind of problem?",
    "What would a human expert do first when facing this problem?",
    "How can I adapt or combine existing solutions to address this problem?",
    "What are the best practices or proven strategies for this type of problem?",
    "How can I learn from past mistakes or failures to improve my approach?",
    "What resources or tools are available to help solve this problem?",
    "How can I leverage technology or automation to solve this problem?",
    "What are the ethical considerations or implications of this decision?",
    "How can I communicate or present my solution effectively?",
    # Structured reasoning (31-39)
    "Let's think step by step",
    "Let's make a step by step plan and implement it with good notation",
    "Let's work this out in a step by step way to be sure we have the right answer",
    "First, let me understand what is being asked",
    "Let me rephrase the problem in my own words",
    "What information do I have, and what do I need?",
    "Let me check my work by approaching this differently",
    "What would happen if I tried the opposite approach?",
    "Let me verify my answer makes sense in context"
  ]

  # ETS table for structure caching
  @cache_table :self_discover_cache
  # 1 hour in seconds
  @cache_ttl 3_600

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  Initialize the ETS cache for structure caching.
  Called by application supervisor.
  """
  def init_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        Mimo.EtsSafe.ensure_table(@cache_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Discover a task-specific reasoning structure.

  Returns a map containing:
  - `:selected_modules` - The chosen atomic reasoning modules
  - `:adapted_modules` - Modules tailored to the specific task
  - `:reasoning_structure` - JSON structure to guide solving

  ## Options

  - `:use_cache` - Whether to use cached structures (default: true)
  - `:max_modules` - Maximum modules to select (default: 5)
  """
  @spec discover(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover(task, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    use_cache = Keyword.get(opts, :use_cache, true)
    max_modules = Keyword.get(opts, :max_modules, 5)

    # Ensure cache is initialized
    init_cache()

    # Check cache first
    cache_key = task_signature(task)

    case {use_cache, get_cached_structure(cache_key)} do
      {true, {:ok, cached}} ->
        ReasoningTelemetry.emit_structure_cache_hit(true)
        {:ok, cached}

      _ ->
        ReasoningTelemetry.emit_structure_cache_hit(false)

        # Stage 1: SELECT relevant modules
        with {:ok, selected} <- select_modules(task, max_modules),
             # Stage 2: ADAPT modules to task
             {:ok, adapted} <- adapt_modules(task, selected),
             # Stage 3: IMPLEMENT as JSON structure
             {:ok, structure} <- implement_structure(task, adapted) do
          result = %{
            selected_modules: selected,
            adapted_modules: adapted,
            reasoning_structure: structure,
            discovered_at: DateTime.utc_now()
          }

          # Cache the result
          if use_cache, do: cache_structure(cache_key, result)

          # Emit telemetry
          duration = System.monotonic_time(:millisecond) - start_time
          ReasoningTelemetry.emit_technique_used(:self_discover, :discovery, true, duration)

          {:ok, result}
        else
          {:error, reason} = error ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReasoningTelemetry.emit_technique_used(:self_discover, :discovery, false, duration)
            Logger.warning("[SelfDiscover] Discovery failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Solve a task using a discovered reasoning structure.

  The structure guides the model through the reasoning process.
  """
  @spec solve(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def solve(task, structure, opts \\ []) when is_map(structure) do
    start_time = System.monotonic_time(:millisecond)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    prompt = """
    Follow this reasoning structure step-by-step to solve the task.
    Fill in each step with your actual reasoning, not just rephrasing.
    Be thorough and explicit in each step.

    REASONING STRUCTURE:
    #{format_structure(structure)}

    TASK:
    #{task}

    Now follow the structure and solve. For each step, show your work:
    """

    case LLM.complete(prompt, max_tokens: max_tokens, raw: true) do
      {:ok, answer} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:self_discover, :solve, true, duration)
        {:ok, answer}

      {:error, reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReasoningTelemetry.emit_technique_used(:self_discover, :solve, false, duration)
        Logger.warning("[SelfDiscover] Solve failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Combined discover and solve in one step.
  Most convenient for direct usage.
  """
  @spec discover_and_solve(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_and_solve(task, opts \\ []) do
    with {:ok, discovery} <- discover(task, opts),
         {:ok, answer} <- solve(task, discovery.reasoning_structure, opts) do
      {:ok,
       %{
         discovery: discovery,
         answer: answer
       }}
    end
  end

  @doc """
  Get the list of all 39 atomic reasoning modules.
  """
  @spec atomic_modules() :: [String.t()]
  def atomic_modules, do: @atomic_modules

  # ============================================================================
  # STAGE 1: SELECT
  # ============================================================================

  defp select_modules(task, max_modules) do
    numbered_modules =
      @atomic_modules
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. #{m}" end)

    prompt = """
    Given the task below, select the reasoning modules that would be most
    useful for solving it. Consider which cognitive strategies would help.

    AVAILABLE REASONING MODULES:
    #{numbered_modules}

    TASK:
    #{task}

    Select #{max_modules} most relevant modules by their numbers.
    Return ONLY the numbers separated by commas (e.g., "1, 5, 10, 20, 31"):
    """

    case LLM.complete(prompt, max_tokens: 50, raw: true) do
      {:ok, response} ->
        modules = parse_selected_modules(response, max_modules)
        {:ok, modules}

      {:error, reason} ->
        Logger.warning("[SelfDiscover] Module selection failed: #{inspect(reason)}")
        # Fallback to sensible defaults
        {:ok, default_modules()}
    end
  end

  defp parse_selected_modules(response, max_modules) do
    numbers = extract_numbers(response)

    modules =
      numbers
      |> Enum.filter(&(&1 >= 1 and &1 <= length(@atomic_modules)))
      |> Enum.uniq()
      |> Enum.take(max_modules)
      |> Enum.map(&Enum.at(@atomic_modules, &1 - 1))

    case modules do
      [] -> default_modules()
      valid -> valid
    end
  end

  defp extract_numbers(text) do
    Regex.scan(~r/\d+/, text)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
  end

  defp default_modules do
    [
      # Break down into parts
      Enum.at(@atomic_modules, 0),
      # Generate sub-tasks
      Enum.at(@atomic_modules, 9),
      # Make implicit explicit
      Enum.at(@atomic_modules, 19),
      # Think step by step
      Enum.at(@atomic_modules, 30),
      # Understand what is asked
      Enum.at(@atomic_modules, 33)
    ]
  end

  # ============================================================================
  # STAGE 2: ADAPT
  # ============================================================================

  defp adapt_modules(task, selected_modules) do
    modules_text =
      selected_modules
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. #{m}" end)

    prompt = """
    Adapt these general reasoning modules to be specific to the task.
    Make each module concrete and actionable for this particular task.

    SELECTED GENERAL MODULES:
    #{modules_text}

    TASK:
    #{task}

    For each module, rewrite it to be task-specific:
    """

    case LLM.complete(prompt, max_tokens: 500, raw: true) do
      {:ok, adapted} ->
        {:ok, adapted}

      {:error, reason} ->
        Logger.warning("[SelfDiscover] Module adaptation failed: #{inspect(reason)}")
        # Fallback to unadapted modules
        {:ok, modules_text}
    end
  end

  # ============================================================================
  # STAGE 3: IMPLEMENT
  # ============================================================================

  defp implement_structure(task, adapted_modules) do
    prompt = """
    Convert these adapted reasoning steps into a JSON structure that can
    guide solving the task. Each key should be a step name, each value
    should describe what to do in that step.

    ADAPTED REASONING MODULES:
    #{adapted_modules}

    TASK:
    #{task}

    Create a JSON reasoning structure with 4-6 steps:
    ```json
    {
      "step_1_[name]": "Description of what to do...",
      "step_2_[name]": "Description of what to do...",
      ...
      "final_answer": "How to formulate the final answer"
    }
    ```

    Return ONLY the JSON, no other text:
    """

    case LLM.complete(prompt, max_tokens: 400, format: :json, raw: true) do
      {:ok, structure} when is_map(structure) ->
        {:ok, structure}

      {:ok, text} when is_binary(text) ->
        # Try to extract JSON from text
        case extract_json(text) do
          {:ok, structure} -> {:ok, structure}
          :error -> {:ok, default_structure()}
        end

      {:error, reason} ->
        Logger.warning("[SelfDiscover] Structure implementation failed: #{inspect(reason)}")
        {:ok, default_structure()}
    end
  end

  defp extract_json(text) do
    # Try to find JSON in the text
    case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp default_structure do
    %{
      "step_1_understand" =>
        "Carefully read and understand what the task is asking. Identify any implicit requirements.",
      "step_2_identify_implicit" =>
        "Look for hidden requirements or assumptions. What is NOT explicitly stated but required?",
      "step_3_decompose" => "Break the task into sub-tasks that need to be completed.",
      "step_4_execute" => "Execute each sub-task systematically, showing work for each.",
      "step_5_synthesize" => "Combine the results from all sub-tasks.",
      "final_answer" => "Provide the final answer based on the synthesized results."
    }
  end

  # ============================================================================
  # CACHING
  # ============================================================================

  defp task_signature(task) do
    # Create a semantic signature for caching similar tasks
    # Normalize the task to catch similar variations
    normalized =
      task
      |> String.downcase()
      # Replace numbers with N
      |> String.replace(~r/\d+/, "N")
      # Normalize whitespace
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    :erlang.phash2(normalized)
  end

  defp get_cached_structure(key) do
    try do
      case :ets.lookup(@cache_table, key) do
        [{^key, structure, timestamp}] ->
          now = System.monotonic_time(:second)

          if now - timestamp < @cache_ttl do
            {:ok, structure}
          else
            # Expired
            :ets.delete(@cache_table, key)
            :miss
          end

        _ ->
          :miss
      end
    rescue
      # Table doesn't exist
      ArgumentError -> :miss
    end
  end

  defp cache_structure(key, structure) do
    try do
      timestamp = System.monotonic_time(:second)
      :ets.insert(@cache_table, {key, structure, timestamp})
    rescue
      # Table doesn't exist, skip caching
      ArgumentError -> :ok
    end
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  defp format_structure(structure) when is_map(structure) do
    Jason.encode!(structure, pretty: true)
  rescue
    _ -> inspect(structure)
  end

  defp format_structure(other), do: inspect(other)
end
