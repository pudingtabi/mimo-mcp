defmodule Mimo.Cognitive.GapDetector do
  @moduledoc """
  Identifies gaps in Mimo's knowledge.

  Analyzes uncertainty assessments to classify knowledge gaps
  and suggest appropriate actions for addressing them.

  ## Gap Types

  - `:no_knowledge` - No relevant information found at all
  - `:weak_knowledge` - Some information but low confidence
  - `:sparse_evidence` - Limited number of sources
  - `:stale_knowledge` - Information exists but is outdated
  - `:partial_coverage` - Some aspects covered, others missing
  - `:none` - No significant gaps detected

  ## Actions

  Based on the gap type, different actions are suggested:
  - `:ask_user` - Request clarification from user
  - `:search_external` - Search web or documentation
  - `:search_codebase` - Index more of the codebase
  - `:present_with_caveat` - Present info with uncertainty disclaimer
  - `:proceed_normally` - Continue without special handling
  """

  alias Mimo.Cognitive.{Uncertainty, ConfidenceAssessor}

  @type gap_type ::
          :no_knowledge
          | :weak_knowledge
          | :sparse_evidence
          | :stale_knowledge
          | :partial_coverage
          | :none

  @type action ::
          :ask_user
          | :search_external
          | :search_codebase
          | :present_with_caveat
          | :proceed_normally
          | :research_library

  @type gap_analysis :: %{
          gap_type: gap_type(),
          severity: :critical | :moderate | :minor | :none,
          suggestion: String.t() | nil,
          actions: [action()],
          details: map()
        }

  @doc """
  Analyze a query to identify what Mimo doesn't know.

  ## Parameters

  - `query` - The user's query string
  - `opts` - Options passed to ConfidenceAssessor

  ## Returns

  A map with:
  - `:gap_type` - Classification of the gap
  - `:severity` - How serious the gap is
  - `:suggestion` - Human-readable suggestion
  - `:actions` - List of recommended actions
  - `:details` - Additional context
  """
  @spec analyze(String.t(), keyword()) :: gap_analysis()
  def analyze(query, opts \\ []) do
    uncertainty = ConfidenceAssessor.assess(query, opts)
    analyze_uncertainty(uncertainty)
  end

  @doc """
  Analyze an existing uncertainty assessment.
  """
  @spec analyze_uncertainty(Uncertainty.t()) :: gap_analysis()
  def analyze_uncertainty(%Uncertainty{} = uncertainty) do
    cond do
      # No knowledge at all
      uncertainty.confidence == :unknown and uncertainty.evidence_count == 0 ->
        %{
          gap_type: :no_knowledge,
          severity: :critical,
          suggestion: "I don't have any information about this topic.",
          actions: [:ask_user, :search_external],
          details: %{
            confidence: uncertainty.confidence,
            evidence_count: uncertainty.evidence_count,
            gaps: uncertainty.gap_indicators
          }
        }

      # Very low confidence
      uncertainty.confidence == :unknown ->
        %{
          gap_type: :weak_knowledge,
          severity: :critical,
          suggestion:
            "I have very limited information about this. Would you like me to research it?",
          actions: [:search_external, :ask_user],
          details: %{
            confidence: uncertainty.confidence,
            evidence_count: uncertainty.evidence_count,
            score: uncertainty.score
          }
        }

      # Low confidence with some evidence
      uncertainty.confidence == :low ->
        %{
          gap_type: :weak_knowledge,
          severity: :moderate,
          suggestion: "I have limited information. My response may not be complete.",
          actions: [:search_external, :present_with_caveat],
          details: %{
            confidence: uncertainty.confidence,
            evidence_count: uncertainty.evidence_count,
            score: uncertainty.score
          }
        }

      # Some evidence but sparse
      uncertainty.evidence_count < 3 ->
        %{
          gap_type: :sparse_evidence,
          severity: :minor,
          suggestion: "I found some relevant information, but coverage is limited.",
          actions: [:present_with_caveat],
          details: %{
            evidence_count: uncertainty.evidence_count,
            source_types: Enum.map(uncertainty.sources, & &1.type) |> Enum.uniq()
          }
        }

      # Stale information
      uncertainty.staleness >= 0.5 ->
        %{
          gap_type: :stale_knowledge,
          severity: :moderate,
          suggestion: "My information on this topic may be outdated.",
          actions: [:search_external, :present_with_caveat],
          details: %{
            staleness: uncertainty.staleness,
            evidence_count: uncertainty.evidence_count
          }
        }

      # Has gap indicators but otherwise okay
      length(uncertainty.gap_indicators) > 0 ->
        %{
          gap_type: :partial_coverage,
          severity: :minor,
          suggestion: "I can help, but there are some aspects I'm uncertain about.",
          actions: suggest_actions_for_gaps(uncertainty.gap_indicators),
          details: %{
            gaps: uncertainty.gap_indicators,
            confidence: uncertainty.confidence
          }
        }

      # No significant gaps
      true ->
        %{
          gap_type: :none,
          severity: :none,
          suggestion: nil,
          actions: [:proceed_normally],
          details: %{
            confidence: uncertainty.confidence,
            score: uncertainty.score,
            evidence_count: uncertainty.evidence_count
          }
        }
    end
  end

  @doc """
  Check if a gap requires user interaction.
  """
  @spec requires_user_input?(gap_analysis()) :: boolean()
  def requires_user_input?(%{actions: actions}) do
    :ask_user in actions
  end

  @doc """
  Check if a gap can be resolved through research.
  """
  @spec researchable?(gap_analysis()) :: boolean()
  def researchable?(%{actions: actions}) do
    :search_external in actions or
      :search_codebase in actions or
      :research_library in actions
  end

  @doc """
  Get the primary action for a gap.
  """
  @spec primary_action(gap_analysis()) :: action()
  def primary_action(%{actions: [first | _]}), do: first
  def primary_action(_), do: :proceed_normally

  @doc """
  Detect specific types of knowledge gaps from a query.

  Returns a list of detected gap patterns.
  """
  @spec detect_gap_patterns(String.t()) :: [map()]
  def detect_gap_patterns(query) do
    patterns = []

    # Library/package reference pattern
    patterns =
      if String.match?(query, ~r/\b(library|package|module|gem|crate)\b/i) do
        lib_names = extract_library_references(query)

        if lib_names != [] do
          [
            %{
              type: :library_reference,
              names: lib_names,
              action: :research_library
            }
            | patterns
          ]
        else
          patterns
        end
      else
        patterns
      end

    # Code reference pattern
    patterns =
      if String.match?(query, ~r/\b(function|method|class|def|implement|call)\b/i) do
        [
          %{
            type: :code_reference,
            action: :search_codebase
          }
          | patterns
        ]
      else
        patterns
      end

    # "How to" pattern - likely needs external research
    patterns =
      if String.match?(query, ~r/\bhow (do|to|can|should)\b/i) do
        [
          %{
            type: :how_to_question,
            action: :search_external
          }
          | patterns
        ]
      else
        patterns
      end

    # Recent/latest/new pattern - may need fresh info
    patterns =
      if String.match?(query, ~r/\b(recent|latest|new|current|updated)\b/i) do
        [
          %{
            type: :recency_required,
            action: :search_external
          }
          | patterns
        ]
      else
        patterns
      end

    patterns
  end

  @doc """
  Generate a research plan for addressing detected gaps.
  """
  @spec generate_research_plan(gap_analysis()) :: [map()]
  def generate_research_plan(%{gap_type: :none}), do: []

  def generate_research_plan(%{actions: actions, details: details}) do
    actions
    |> Enum.filter(&(&1 != :proceed_normally and &1 != :present_with_caveat))
    |> Enum.map(fn action ->
      %{
        action: action,
        priority: action_priority(action),
        description: action_description(action),
        context: details
      }
    end)
    |> Enum.sort_by(& &1.priority)
  end

  # Private functions

  defp suggest_actions_for_gaps(gap_indicators) do
    gap_indicators
    |> Enum.flat_map(fn gap ->
      cond do
        String.contains?(gap, "documentation") -> [:research_library]
        String.contains?(gap, "code") -> [:search_codebase]
        String.contains?(gap, "relevance") -> [:ask_user]
        true -> [:present_with_caveat]
      end
    end)
    |> Enum.uniq()
    |> case do
      [] -> [:present_with_caveat]
      actions -> actions
    end
  end

  defp extract_library_references(query) do
    # Common package name patterns
    patterns = [
      # Elixir packages (e.g., :phoenix, Phoenix)
      ~r/:([a-z_]+)/,
      # npm/pip style (e.g., react, numpy)
      ~r/\b([a-z][a-z0-9_-]{2,})\b/
    ]

    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, query)
      |> Enum.map(fn [_, match] -> String.downcase(match) end)
    end)
    |> Enum.uniq()
    |> Enum.reject(&common_word?/1)
    |> Enum.take(5)
  end

  defp common_word?(word) do
    common_words = ~w(
      the a an is are was were be been being
      have has had do does did will would could should
      may might must can this that these those
      what when where which who whom whose why how
      for from with about into through after before
      and but or nor so yet both either neither
      not only also too very just even still already
    )

    word in common_words
  end

  defp action_priority(:ask_user), do: 1
  defp action_priority(:search_external), do: 2
  defp action_priority(:research_library), do: 3
  defp action_priority(:search_codebase), do: 4
  defp action_priority(:present_with_caveat), do: 5
  defp action_priority(:proceed_normally), do: 6

  defp action_description(:ask_user), do: "Ask user for clarification or more context"
  defp action_description(:search_external), do: "Search the web for current information"
  defp action_description(:research_library), do: "Fetch and cache library documentation"
  defp action_description(:search_codebase), do: "Index and search the codebase"

  defp action_description(:present_with_caveat),
    do: "Present available info with uncertainty disclaimer"

  defp action_description(:proceed_normally), do: "Proceed with normal response"
end
