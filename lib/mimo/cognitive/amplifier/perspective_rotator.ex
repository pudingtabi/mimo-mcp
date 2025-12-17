defmodule Mimo.Cognitive.Amplifier.PerspectiveRotator do
  @moduledoc """
  Forces consideration of problems from multiple viewpoints.

  Prevents tunnel vision by requiring the LLM to consider different
  angles before concluding. Domain-adaptive perspective selection.

  ## Perspective Sets

  - Code: user, security, performance, maintainability, testing
  - Design: user, business, technical, operations, cost
  - Debug: symptom, root_cause, system, data_flow, timing
  - Decision: optimistic, pessimistic, pragmatic, creative, critical

  ## Integration with Neuro+ML

  - HebbianLearner tracks which perspective combinations work best
  - Learns domain → perspective mappings over time
  """

  require Logger

  @type perspective_name ::
          :user
          | :security
          | :performance
          | :maintainability
          | :testing
          | :business
          | :technical
          | :operations
          | :cost
          | :symptom
          | :root_cause
          | :system
          | :data_flow
          | :timing
          | :optimistic
          | :pessimistic
          | :pragmatic
          | :creative
          | :critical

  @type domain :: :code | :design | :debug | :decision | :general

  @type perspective :: %{
          name: perspective_name(),
          prompt: String.t(),
          question: String.t()
        }

  # Perspective sets by domain
  @perspective_sets %{
    code: [:user, :security, :performance, :maintainability, :testing],
    design: [:user, :business, :technical, :operations, :cost],
    debug: [:symptom, :root_cause, :system, :data_flow, :timing],
    decision: [:optimistic, :pessimistic, :pragmatic, :creative, :critical],
    general: [:user, :technical, :critical, :creative, :pragmatic]
  }

  # Perspective prompts and questions
  @perspective_prompts %{
    # Code perspectives
    user: %{
      prompt: "Consider this from the USER's perspective:",
      question:
        "How will this affect the end user experience? What will they see, feel, or have to do?"
    },
    security: %{
      prompt: "Consider this from a SECURITY perspective:",
      question: "What security implications exist? How could this be exploited or misused?"
    },
    performance: %{
      prompt: "Consider this from a PERFORMANCE perspective:",
      question:
        "What are the performance implications? Where are the bottlenecks? How does this scale?"
    },
    maintainability: %{
      prompt: "Consider this from a MAINTAINABILITY perspective:",
      question:
        "How easy will this be to maintain? What about readability, documentation, future changes?"
    },
    testing: %{
      prompt: "Consider this from a TESTING perspective:",
      question: "How will this be tested? What edge cases exist? How can we verify correctness?"
    },

    # Design perspectives
    business: %{
      prompt: "Consider this from a BUSINESS perspective:",
      question:
        "What is the business value? How does this affect revenue, costs, or competitive position?"
    },
    technical: %{
      prompt: "Consider this from a TECHNICAL perspective:",
      question:
        "What are the technical constraints and trade-offs? What technical debt might this create?"
    },
    operations: %{
      prompt: "Consider this from an OPERATIONS perspective:",
      question: "How will this be deployed, monitored, and maintained in production?"
    },
    cost: %{
      prompt: "Consider this from a COST perspective:",
      question:
        "What are the costs involved? Development time, infrastructure, ongoing maintenance?"
    },

    # Debug perspectives
    symptom: %{
      prompt: "Focus on the SYMPTOM:",
      question: "What exactly is happening? What is the observable behavior?"
    },
    root_cause: %{
      prompt: "Look for the ROOT CAUSE:",
      question: "Why is this happening? What is the underlying cause, not just the symptom?"
    },
    system: %{
      prompt: "Consider the SYSTEM context:",
      question: "How does this fit into the larger system? What interactions might be relevant?"
    },
    data_flow: %{
      prompt: "Trace the DATA FLOW:",
      question: "How does data flow through this? Where might data be corrupted or lost?"
    },
    timing: %{
      prompt: "Consider TIMING issues:",
      question: "Could this be a race condition? What happens under different timing scenarios?"
    },

    # Decision perspectives
    optimistic: %{
      prompt: "Take an OPTIMISTIC view:",
      question: "What if everything goes right? What's the best case scenario?"
    },
    pessimistic: %{
      prompt: "Take a PESSIMISTIC view:",
      question: "What if things go wrong? What's the worst case scenario?"
    },
    pragmatic: %{
      prompt: "Take a PRAGMATIC view:",
      question: "What's realistic given our constraints? What trade-offs make sense?"
    },
    creative: %{
      prompt: "Take a CREATIVE view:",
      question:
        "What unconventional approaches might work? What if we ignore the usual constraints?"
    },
    critical: %{
      prompt: "Take a CRITICAL view:",
      question: "What's wrong with this approach? What are the weaknesses and blind spots?"
    }
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get perspectives for a problem based on domain detection.
  """
  @spec get_perspectives(String.t(), keyword()) :: [perspective()]
  def get_perspectives(problem, opts \\ []) do
    domain = Keyword.get(opts, :domain) || detect_domain(problem)
    count = Keyword.get(opts, :count, 3)

    perspective_names = Map.get(@perspective_sets, domain, @perspective_sets.general)

    perspective_names
    |> Enum.take(count)
    |> Enum.map(&build_perspective(&1, problem))
  end

  @doc """
  Generate a rotation prompt for a specific perspective.
  """
  @spec rotate_to(perspective_name(), String.t()) :: perspective()
  def rotate_to(perspective_name, problem) do
    build_perspective(perspective_name, problem)
  end

  @doc """
  Get the next perspective to consider.

  Takes into account which perspectives have already been covered.
  """
  @spec next_perspective(String.t(), [perspective_name()], keyword()) ::
          {:ok, perspective()} | :all_covered
  def next_perspective(problem, covered, opts \\ []) do
    domain = Keyword.get(opts, :domain) || detect_domain(problem)
    required = Keyword.get(opts, :required, 3)

    perspective_names = Map.get(@perspective_sets, domain, @perspective_sets.general)
    remaining = perspective_names -- covered

    cond do
      length(covered) >= required ->
        :all_covered

      remaining == [] ->
        :all_covered

      true ->
        next = List.first(remaining)
        {:ok, build_perspective(next, problem)}
    end
  end

  @doc """
  Check if minimum perspective coverage is met.
  """
  @spec coverage_met?([perspective_name()], non_neg_integer() | :all, domain()) :: boolean()
  def coverage_met?(covered, required, domain) do
    all_perspectives = Map.get(@perspective_sets, domain, @perspective_sets.general)

    case required do
      :all ->
        MapSet.new(covered) |> MapSet.subset?(MapSet.new(all_perspectives)) and
          length(covered) >= length(all_perspectives)

      n when is_integer(n) ->
        length(covered) >= n
    end
  end

  @doc """
  Format a perspective rotation prompt for injection.
  """
  @spec format_rotation_prompt(perspective()) :: String.t()
  def format_rotation_prompt(perspective) do
    """
    🔄 PERSPECTIVE ROTATION

    #{perspective.prompt}

    #{perspective.question}

    After considering this perspective, note any new insights before continuing.
    """
  end

  @doc """
  Get all available domains.
  """
  @spec available_domains() :: [domain()]
  def available_domains do
    Map.keys(@perspective_sets)
  end

  @doc """
  Get perspectives for a specific domain.
  """
  @spec perspectives_for_domain(domain()) :: [perspective_name()]
  def perspectives_for_domain(domain) do
    Map.get(@perspective_sets, domain, @perspective_sets.general)
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp detect_domain(problem) do
    problem_lower = String.downcase(problem)

    cond do
      # Debug patterns
      String.match?(problem_lower, ~r/\b(bug|error|fix|debug|issue|crash|wrong|broken|fail)\b/) ->
        :debug

      # Design patterns
      String.match?(problem_lower, ~r/\b(design|architect|structure|plan|system|service)\b/) ->
        :design

      # Decision patterns
      String.match?(problem_lower, ~r/\b(should|decide|choose|which|compare|vs|or)\b/) ->
        :decision

      # Code patterns
      String.match?(
        problem_lower,
        ~r/\b(implement|code|function|class|module|refactor|test)\b/
      ) ->
        :code

      true ->
        :general
    end
  end

  defp build_perspective(name, problem) do
    config = Map.get(@perspective_prompts, name, @perspective_prompts.critical)

    # Customize question with problem context
    contextualized_question = contextualize_question(config.question, problem)

    %{
      name: name,
      prompt: config.prompt,
      question: contextualized_question
    }
  end

  defp contextualize_question(question, problem) do
    # Extract key topic from problem for contextualization
    topic =
      problem
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) > 4))
      |> Enum.take(5)
      |> Enum.join(" ")

    if String.length(topic) > 10 do
      question <> " (regarding: #{String.slice(topic, 0..50)})"
    else
      question
    end
  end
end
