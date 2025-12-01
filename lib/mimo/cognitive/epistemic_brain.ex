defmodule Mimo.Cognitive.EpistemicBrain do
  @moduledoc """
  Enhanced query handler with epistemic awareness.

  This module wraps Mimo's brain functions with uncertainty assessment,
  providing epistemically honest responses that acknowledge knowledge gaps.

  ## Features

  - Automatic confidence assessment before responding
  - Knowledge gap detection and handling
  - Calibrated response generation
  - Uncertainty tracking for meta-learning

  ## Usage

      # Query with epistemic awareness
      {:ok, result} = EpistemicBrain.query("How does Phoenix authentication work?")

      # Result includes:
      # - response: The answer with confidence indicators
      # - uncertainty: The assessed uncertainty
      # - gap_analysis: Analysis of any knowledge gaps
      # - actions_taken: What the system did to improve its response

  ## Integration

  This module can be used as a drop-in replacement for direct Brain queries,
  adding epistemic awareness without changing the external API.
  """

  require Logger

  alias Mimo.Cognitive.{
    Uncertainty,
    ConfidenceAssessor,
    GapDetector,
    CalibratedResponse,
    UncertaintyTracker
  }

  alias Mimo.Brain.Memory

  @type query_result :: %{
          response: String.t(),
          uncertainty: Uncertainty.t(),
          gap_analysis: GapDetector.gap_analysis(),
          actions_taken: [atom()],
          raw_content: String.t() | nil
        }

  @type query_opts :: [
          assess_confidence: boolean(),
          calibrate_response: boolean(),
          track_uncertainty: boolean(),
          research_gaps: boolean(),
          min_confidence: Uncertainty.confidence_level()
        ]

  @doc """
  Query with epistemic awareness.

  This is the main entry point for epistemically-aware queries.
  It assesses uncertainty, detects gaps, and calibrates the response.

  ## Options

  - `:assess_confidence` - Perform confidence assessment (default: true)
  - `:calibrate_response` - Add confidence indicators to response (default: true)
  - `:track_uncertainty` - Log uncertainty for meta-learning (default: true)
  - `:research_gaps` - Attempt to fill knowledge gaps (default: false)
  - `:min_confidence` - Minimum confidence to proceed (default: :low)
  """
  @spec query(String.t(), query_opts()) :: {:ok, query_result()} | {:error, term()}
  def query(question, opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)
    actions = []

    # Step 1: Assess uncertainty about the topic
    {uncertainty, actions} =
      if opts[:assess_confidence] do
        u = ConfidenceAssessor.assess(question)
        {u, [:assessed_confidence | actions]}
      else
        {Uncertainty.new(question), actions}
      end

    # Step 2: Detect knowledge gaps
    gap_analysis = GapDetector.analyze_uncertainty(uncertainty)

    # Step 3: Handle based on gap type and minimum confidence
    {response, raw_content, actions} =
      handle_with_gap_awareness(question, uncertainty, gap_analysis, opts, actions)

    # Step 4: Calibrate response if requested
    {final_response, actions} =
      if opts[:calibrate_response] and raw_content do
        calibrated = CalibratedResponse.format_response(raw_content, uncertainty)
        {calibrated, [:calibrated_response | actions]}
      else
        {response, actions}
      end

    # Step 5: Track uncertainty for meta-learning
    actions =
      if opts[:track_uncertainty] do
        UncertaintyTracker.record(question, uncertainty)
        [:tracked_uncertainty | actions]
      else
        actions
      end

    {:ok,
     %{
       response: final_response,
       uncertainty: uncertainty,
       gap_analysis: gap_analysis,
       actions_taken: Enum.reverse(actions),
       raw_content: raw_content
     }}
  end

  @doc """
  Quick query without full epistemic processing.
  Uses quick confidence assessment for speed.
  """
  @spec quick_query(String.t()) :: {:ok, String.t()} | {:error, term()}
  def quick_query(question) do
    confidence = ConfidenceAssessor.quick_assess(question)

    if confidence in [:high, :medium] do
      # Proceed with normal query
      response = do_brain_query(question)
      {:ok, response}
    else
      # Return uncertainty message
      {:ok, "I don't have enough information to answer this confidently. #{question}"}
    end
  end

  @doc """
  Check if Mimo has sufficient knowledge to answer a question.
  """
  @spec can_answer?(String.t(), Uncertainty.confidence_level()) :: boolean()
  def can_answer?(question, min_confidence \\ :low) do
    uncertainty = ConfidenceAssessor.assess(question)
    confidence_sufficient?(uncertainty.confidence, min_confidence)
  end

  @doc """
  Get a confidence assessment without generating a response.
  """
  @spec assess(String.t()) :: Uncertainty.t()
  def assess(question) do
    ConfidenceAssessor.assess(question)
  end

  @doc """
  Analyze knowledge gaps for a question without answering.
  """
  @spec analyze_gaps(String.t()) :: GapDetector.gap_analysis()
  def analyze_gaps(question) do
    GapDetector.analyze(question)
  end

  @doc """
  Get suggestions for improving knowledge about a topic.
  """
  @spec knowledge_improvement_suggestions(String.t()) :: [map()]
  def knowledge_improvement_suggestions(question) do
    gap_analysis = analyze_gaps(question)
    GapDetector.generate_research_plan(gap_analysis)
  end

  # Private functions

  defp default_opts do
    [
      assess_confidence: true,
      calibrate_response: true,
      track_uncertainty: true,
      research_gaps: false,
      min_confidence: :low
    ]
  end

  defp handle_with_gap_awareness(question, uncertainty, gap_analysis, opts, actions) do
    min_confidence = opts[:min_confidence]

    cond do
      # No knowledge at all
      gap_analysis.gap_type == :no_knowledge ->
        response =
          CalibratedResponse.unknown_response(question, uncertainty, include_suggestions: true)

        {response, nil, [:handled_no_knowledge | actions]}

      # Confidence below minimum threshold
      not confidence_sufficient?(uncertainty.confidence, min_confidence) ->
        response = build_insufficient_confidence_response(question, uncertainty, gap_analysis)
        {response, nil, [:handled_low_confidence | actions]}

      # Research gaps if requested and researchable
      opts[:research_gaps] and GapDetector.researchable?(gap_analysis) ->
        {response, raw, research_actions} = attempt_gap_research(question, gap_analysis)
        {response, raw, research_actions ++ actions}

      # Normal query with available knowledge
      true ->
        raw_content = do_brain_query(question)
        {raw_content, raw_content, [:queried_brain | actions]}
    end
  end

  defp confidence_sufficient?(current, minimum) do
    confidence_levels = [:unknown, :low, :medium, :high]
    current_idx = Enum.find_index(confidence_levels, &(&1 == current))
    min_idx = Enum.find_index(confidence_levels, &(&1 == minimum))
    current_idx >= min_idx
  end

  defp build_insufficient_confidence_response(question, uncertainty, gap_analysis) do
    base = CalibratedResponse.unknown_response(question, uncertainty)

    if gap_analysis.suggestion do
      "#{base}\n\n_#{gap_analysis.suggestion}_"
    else
      base
    end
  end

  defp attempt_gap_research(question, gap_analysis) do
    Logger.info("[EpistemicBrain] Researching gaps: #{inspect(gap_analysis.actions)}")

    # Execute research actions based on gap analysis
    research_results =
      gap_analysis.actions
      |> Enum.map(&execute_research_action(&1, question))
      |> Enum.reject(&is_nil/1)

    actions =
      gap_analysis.actions
      |> Enum.map(fn action ->
        case action do
          :search_external -> :searched_web
          :research_library -> :fetched_docs
          :search_codebase -> :searched_code
          _ -> action
        end
      end)

    # Combine research with existing knowledge
    if research_results != [] do
      # Store valuable research findings in memory for future use
      store_research_findings(question, research_results)

      combined_content = build_research_response(question, research_results)
      {combined_content, combined_content, actions}
    else
      # Fall back to normal query if research yielded nothing
      raw_content = do_brain_query(question)
      {raw_content, raw_content, [:research_empty | actions]}
    end
  end

  defp execute_research_action(:search_external, question) do
    # Use web search to find external information
    case Mimo.Skills.Network.web_search(question, num_results: 3) do
      {:ok, results} when is_list(results) and results != [] ->
        %{type: :web_search, content: format_search_results(results)}

      {:ok, %{results: results}} when is_list(results) and results != [] ->
        %{type: :web_search, content: format_search_results(results)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp execute_research_action(:research_library, question) do
    # Extract potential library names from question
    # Simple heuristic: look for package/library mentions
    potential_libs = extract_library_names(question)

    if potential_libs != [] do
      # Try to get info for the first detected library
      lib_name = hd(potential_libs)
      ecosystem = detect_ecosystem(question)

      case Mimo.Library.get_package(lib_name, ecosystem) do
        {:ok, package} ->
          %{type: :library_docs, content: format_library_info(package)}

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp execute_research_action(:search_codebase, question) do
    # Use file search to find relevant code
    root = System.get_env("MIMO_ROOT") || File.cwd!()

    case Mimo.Skills.FileOps.search(root, extract_search_pattern(question)) do
      {:ok, results} when results != [] ->
        %{type: :code_search, content: format_code_results(results)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp execute_research_action(_, _), do: nil

  defp format_search_results(results) do
    results
    |> Enum.take(3)
    |> Enum.map_join("\n", fn result ->
      title = result["title"] || result[:title] || "Result"
      snippet = result["snippet"] || result[:snippet] || result["description"] || ""
      "- **#{title}**: #{String.slice(snippet, 0..150)}"
    end)
  end

  defp format_library_info(package) do
    name = package[:name] || package["name"] || "Unknown"
    desc = package[:description] || package["description"] || "No description"
    version = package[:version] || package["version"] || "unknown"
    "**#{name}** (v#{version}): #{desc}"
  end

  defp format_code_results(results) do
    results
    |> Enum.take(3)
    |> Enum.map_join("\n", fn result ->
      file = result[:file] || result["file"] || "unknown"
      line = result[:line] || result["line"] || 0
      content = result[:content] || result["content"] || ""
      "- `#{file}:#{line}`: #{String.slice(content, 0..100)}"
    end)
  end

  defp extract_library_names(question) do
    # Simple extraction: look for common package name patterns
    question
    |> String.downcase()
    |> then(fn q ->
      # Match common patterns like "phoenix", "ecto", "jason", etc.
      Regex.scan(
        ~r/\b(phoenix|ecto|plug|jason|tesla|req|finch|broadway|oban|absinthe|nx|axon|bumblebee)\b/i,
        q
      )
      |> Enum.map(fn [_, name] -> name end)
    end)
  end

  defp detect_ecosystem(question) do
    q = String.downcase(question)

    cond do
      String.contains?(q, ["elixir", "phoenix", "ecto", "mix"]) -> :hex
      String.contains?(q, ["python", "pip", "django", "flask"]) -> :pypi
      String.contains?(q, ["javascript", "node", "npm", "react", "vue"]) -> :npm
      String.contains?(q, ["rust", "cargo", "crate"]) -> :crates
      # Default to Hex for this Elixir project
      true -> :hex
    end
  end

  defp extract_search_pattern(question) do
    # Extract meaningful terms for code search
    question
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(2)
    |> Enum.join("|")
    |> then(fn pattern -> if pattern == "", do: question, else: pattern end)
  end

  defp store_research_findings(question, results) do
    # Store valuable research in working memory for consolidation
    content =
      Enum.map_join(results, "\n\n", fn %{type: type, content: content} ->
        "[#{type}] #{content}"
      end)

    if String.length(content) > 50 do
      summary = "Research on '#{String.slice(question, 0..50)}': #{String.slice(content, 0..300)}"

      Mimo.Brain.WorkingMemory.store(summary,
        category: "fact",
        importance: 0.6,
        source: "gap_research",
        context: %{original_question: question}
      )
    end
  rescue
    _ -> :ok
  end

  defp build_research_response(question, results) do
    research_content =
      Enum.map_join(results, "\n\n", fn %{type: type, content: content} ->
        type_label =
          case type do
            :web_search -> "Web Research"
            :library_docs -> "Library Documentation"
            :code_search -> "Codebase Search"
            _ -> "Research"
          end

        "### #{type_label}\n#{content}"
      end)

    # Also get existing memory context
    memory_context = do_brain_query(question)

    """
    Based on research for your question:

    #{research_content}

    #{if memory_context != "I don't have specific memories about this topic.", do: "---\n\n**From Memory:**\n#{memory_context}", else: ""}
    """
  end

  defp do_brain_query(question) do
    # Search memories for relevant context
    memories = Memory.search_memories(question, limit: 5, min_similarity: 0.3)

    if memories == [] do
      "I don't have specific memories about this topic."
    else
      # Build context from memories
      context =
        memories
        |> Enum.take(3)
        |> Enum.map_join("\n", fn m ->
          "- #{String.slice(m.content, 0..200)}"
        end)

      """
      Based on my memory:

      #{context}
      """
    end
  end
end
