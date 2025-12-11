defmodule Mimo.Robustness.ComplexityAnalyzer do
  @moduledoc """
  Complexity Reasoning Analyzer (SPEC-070 Task B)
  
  Uses cognitive assessment to evaluate implementation complexity
  and suggest simplifications.
  
  ## Metrics Evaluated
  
  - **Cyclomatic Complexity**: Number of independent paths through code
  - **External Dependencies**: Count of external command/library calls
  - **Nesting Depth**: Maximum nesting level of control structures
  - **Missing Fallbacks**: External operations without error handling
  - **Blocking Operations**: Count of synchronous blocking calls
  
  ## Usage
  
      {:ok, analysis} = ComplexityAnalyzer.analyze(code, :elixir)
      
      # Returns:
      # %{
      #   cyclomatic: 8,
      #   external_deps: 2,
      #   nesting_depth: 3,
      #   missing_fallbacks: 1,
      #   blocking_ops: 1,
      #   confidence: 0.75
      # }
  """

  require Logger

  @type language :: :elixir | :javascript | :typescript | :unknown
  
  @type analysis :: %{
    cyclomatic: non_neg_integer(),
    external_deps: non_neg_integer(),
    nesting_depth: non_neg_integer(),
    missing_fallbacks: non_neg_integer(),
    blocking_ops: non_neg_integer(),
    confidence: float()
  }

  # Decision points that increase cyclomatic complexity
  @elixir_decision_points [
    ~r/\bif\b/,
    ~r/\bcond\b/,
    ~r/\bcase\b/,
    ~r/\bwith\b/,
    ~r/\bunless\b/,
    ~r/\bwhen\b/,
    ~r/\band\b/,
    ~r/\bor\b/,
    ~r/\|\|/,
    ~r/&&/,
    ~r/->/
  ]

  @javascript_decision_points [
    ~r/\bif\b/,
    ~r/\belse\s+if\b/,
    ~r/\bswitch\b/,
    ~r/\bcase\b/,
    ~r/\?\s*:/,       # ternary
    ~r/\|\|/,
    ~r/&&/,
    ~r/\?\?/,         # nullish coalescing
    ~r/\bcatch\b/,
    ~r/\.then\(/,
    ~r/\.catch\(/
  ]

  # External dependencies (things that can fail)
  @elixir_external_patterns [
    ~r/System\.cmd\b/,
    ~r/Port\.open\b/,
    ~r/:os\.cmd\b/,
    ~r/HTTPoison\./,
    ~r/Req\./,
    ~r/Mint\./,
    ~r/File\.\w+!/,  # Bang versions
    ~r/GenServer\.call\b/
  ]

  @javascript_external_patterns [
    ~r/execSync\b/,
    ~r/spawnSync\b/,
    ~r/fetch\(/,
    ~r/axios\./,
    ~r/require\(['"]child_process['"]\)/,
    ~r/fs\.\w+Sync\b/,
    ~r/\.readFileSync\b/,
    ~r/\.writeFileSync\b/
  ]

  # Blocking operation patterns
  @elixir_blocking_patterns [
    ~r/GenServer\.call\b/,
    ~r/receive\s+do\b/,
    ~r/:timer\.sleep\b/,
    ~r/Process\.sleep\b/,
    ~r/Task\.await\b/
  ]

  @javascript_blocking_patterns [
    ~r/execSync\b/,
    ~r/spawnSync\b/,
    ~r/\bawait\b/,
    ~r/\.then\([^)]*\)\.then\(/,  # chained then (effectively blocking)
    ~r/sleep\(/
  ]

  @doc """
  Analyze code complexity.
  
  Returns a map of complexity metrics.
  """
  @spec analyze(String.t(), language()) :: {:ok, analysis()} | {:error, term()}
  def analyze(content, language) do
    lines = String.split(content, "\n")
    
    analysis = %{
      cyclomatic: calculate_cyclomatic(content, language),
      external_deps: count_external_deps(content, language),
      nesting_depth: calculate_nesting_depth(lines, language),
      missing_fallbacks: count_missing_fallbacks(content, language),
      blocking_ops: count_blocking_ops(content, language),
      lines_of_code: length(lines),
      confidence: 0.8  # Static analysis confidence
    }
    
    {:ok, analysis}
  rescue
    e -> {:error, {:complexity_analysis_failed, e}}
  end

  @doc """
  Evaluate if code meets robustness thresholds.
  
  Returns true if all metrics are within acceptable ranges.
  """
  @spec meets_thresholds?(analysis(), keyword()) :: boolean()
  def meets_thresholds?(analysis, opts \\ []) do
    max_cyclomatic = Keyword.get(opts, :max_cyclomatic, 10)
    max_external = Keyword.get(opts, :max_external_deps, 3)
    max_nesting = Keyword.get(opts, :max_nesting, 4)
    max_blocking = Keyword.get(opts, :max_blocking, 2)
    
    analysis.cyclomatic <= max_cyclomatic and
      analysis.external_deps <= max_external and
      analysis.nesting_depth <= max_nesting and
      analysis.blocking_ops <= max_blocking and
      analysis.missing_fallbacks == 0
  end

  @doc """
  Generate simplification suggestions based on analysis.
  """
  @spec suggest_simplifications(analysis()) :: [String.t()]
  def suggest_simplifications(analysis) do
    suggestions = []
    
    suggestions = if analysis.cyclomatic > 10 do
      ["Consider extracting complex functions into smaller units (cyclomatic: #{analysis.cyclomatic})" | suggestions]
    else
      suggestions
    end
    
    suggestions = if analysis.external_deps > 3 do
      ["Reduce external dependencies - consider pure language features (count: #{analysis.external_deps})" | suggestions]
    else
      suggestions
    end
    
    suggestions = if analysis.nesting_depth > 4 do
      ["Flatten deeply nested code - consider early returns or with statements (depth: #{analysis.nesting_depth})" | suggestions]
    else
      suggestions
    end
    
    suggestions = if analysis.missing_fallbacks > 0 do
      ["Add error handling/fallbacks for external operations (missing: #{analysis.missing_fallbacks})" | suggestions]
    else
      suggestions
    end
    
    suggestions = if analysis.blocking_ops > 2 do
      ["Consider async operations to reduce blocking (count: #{analysis.blocking_ops})" | suggestions]
    else
      suggestions
    end
    
    Enum.reverse(suggestions)
  end

  @doc """
  Use Mimo's cognitive assessment to evaluate code robustness.
  
  Integrates with the reasoning engine for deeper analysis.
  """
  @spec cognitive_assess(String.t(), language()) :: {:ok, map()} | {:error, term()}
  def cognitive_assess(content, language) do
    with {:ok, static_analysis} <- analyze(content, language) do
      # Build assessment topic
      topic = """
      Code robustness assessment:
      - Language: #{language}
      - Cyclomatic complexity: #{static_analysis.cyclomatic}
      - External dependencies: #{static_analysis.external_deps}
      - Nesting depth: #{static_analysis.nesting_depth}
      - Missing fallbacks: #{static_analysis.missing_fallbacks}
      - Blocking operations: #{static_analysis.blocking_ops}
      - Lines of code: #{static_analysis.lines_of_code}
      """
      
      # Try to use cognitive assessment if available
      case Code.ensure_loaded(Mimo.Cognitive.ConfidenceAssessor) do
        {:module, _} ->
          case Mimo.Cognitive.ConfidenceAssessor.assess(topic) do
            {:ok, assessment} ->
              {:ok, Map.merge(static_analysis, %{
                cognitive_confidence: assessment.score,
                cognitive_gaps: assessment.gap_indicators
              })}
            _ ->
              {:ok, static_analysis}
          end
        _ ->
          {:ok, static_analysis}
      end
    end
  end

  # --- Private Functions ---

  defp calculate_cyclomatic(content, :elixir) do
    # Start at 1, add 1 for each decision point
    1 + count_patterns(content, @elixir_decision_points)
  end

  defp calculate_cyclomatic(content, :javascript) do
    1 + count_patterns(content, @javascript_decision_points)
  end

  defp calculate_cyclomatic(content, :typescript) do
    calculate_cyclomatic(content, :javascript)
  end

  defp calculate_cyclomatic(_content, _language), do: 1

  defp count_external_deps(content, :elixir) do
    count_patterns(content, @elixir_external_patterns)
  end

  defp count_external_deps(content, :javascript) do
    count_patterns(content, @javascript_external_patterns)
  end

  defp count_external_deps(content, :typescript) do
    count_external_deps(content, :javascript)
  end

  defp count_external_deps(_content, _language), do: 0

  defp count_blocking_ops(content, :elixir) do
    count_patterns(content, @elixir_blocking_patterns)
  end

  defp count_blocking_ops(content, :javascript) do
    count_patterns(content, @javascript_blocking_patterns)
  end

  defp count_blocking_ops(content, :typescript) do
    count_blocking_ops(content, :javascript)
  end

  defp count_blocking_ops(_content, _language), do: 0

  defp count_patterns(content, patterns) do
    patterns
    |> Enum.map(fn pattern ->
      case Regex.scan(pattern, content) do
        matches when is_list(matches) -> length(matches)
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp calculate_nesting_depth(lines, language) do
    # Track maximum nesting based on indentation or braces
    lines
    |> Enum.map(&calculate_line_nesting(&1, language))
    |> Enum.max(fn -> 0 end)
  end

  defp calculate_line_nesting(line, :elixir) do
    # Count leading spaces / 2 (Elixir convention)
    spaces = String.length(line) - String.length(String.trim_leading(line))
    div(spaces, 2)
  end

  defp calculate_line_nesting(line, language) when language in [:javascript, :typescript] do
    # Count leading spaces / 2 or tabs
    spaces = String.length(line) - String.length(String.trim_leading(line))
    div(spaces, 2)
  end

  defp calculate_line_nesting(_line, _language), do: 0

  defp count_missing_fallbacks(content, :elixir) do
    # Count external operations not in try/rescue blocks
    external_count = count_external_deps(content, :elixir)
    
    # Count rescue blocks
    rescue_count = length(Regex.scan(~r/\brescue\b/, content))
    try_count = length(Regex.scan(~r/\btry\b/, content))
    catch_count = length(Regex.scan(~r/\bcatch\b/, content))
    
    # Estimate missing fallbacks
    max(0, external_count - (rescue_count + try_count + catch_count))
  end

  defp count_missing_fallbacks(content, :javascript) do
    external_count = count_external_deps(content, :javascript)
    
    # Count try/catch blocks
    try_count = length(Regex.scan(~r/\btry\s*\{/, content))
    catch_count = length(Regex.scan(~r/\.catch\(/, content))
    
    max(0, external_count - (try_count + catch_count))
  end

  defp count_missing_fallbacks(content, :typescript) do
    count_missing_fallbacks(content, :javascript)
  end

  defp count_missing_fallbacks(_content, _language), do: 0
end
