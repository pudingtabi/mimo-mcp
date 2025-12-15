defmodule Mimo.Robustness do
  @moduledoc """
  Implementation Robustness Framework (SPEC-070)

  A systematic framework for preventing "good reasoning, bad implementation" incidents
  through automated pattern detection, complexity analysis, and learning loops.

  ## Core Components

  - **Pattern Detector**: Static analysis for red flag patterns (execSync, blocking calls, etc.)
  - **Complexity Analyzer**: Reasoning-based evaluation of implementation complexity
  - **Knowledge Integration**: Tracks fragile code and links to incidents in the graph
  - **Audit Tool**: One-time codebase analysis with report generation

  ## Core Insight

  > Adding complexity to solve problems often creates worse problems.
  > Start simple. Add complexity only when simple solutions won't work.
  > When you do add complexity, add graceful fallbacks too.

  ## Usage

      # Analyze a single file
      {:ok, result} = Mimo.Robustness.analyze("/path/to/file.ex")

      # Get robustness score
      score = result.score  # 0-100, higher is better

      # Check for red flags
      red_flags = result.red_flags  # List of detected issues

      # Audit entire codebase
      {:ok, report} = Mimo.Robustness.audit("/path/to/project")

  ## References

  - SPEC-070: Implementation Robustness Framework
  - IMPLEMENTATION_ROBUSTNESS.md: Red flags and patterns documentation
  - Dec 6 2025 Incident Analysis: Root cause patterns
  """

  alias Mimo.Robustness.{PatternDetector, ComplexityAnalyzer, IncidentParser}

  @doc """
  Analyze a file for robustness issues.

  Returns a map with:
  - `:score` - Robustness score 0-100 (higher is better)
  - `:red_flags` - List of detected red flag patterns
  - `:complexity` - Complexity metrics
  - `:recommendations` - Suggested improvements
  """
  @spec analyze(String.t()) :: {:ok, map()} | {:error, term()}
  def analyze(file_path) do
    with {:ok, content} <- File.read(file_path),
         language <- detect_language(file_path),
         {:ok, patterns} <- PatternDetector.detect(content, language),
         {:ok, complexity} <- ComplexityAnalyzer.analyze(content, language) do
      score = calculate_score(patterns, complexity)

      {:ok,
       %{
         file: file_path,
         language: language,
         score: score,
         red_flags: patterns,
         complexity: complexity,
         recommendations: generate_recommendations(patterns, complexity),
         analyzed_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Audit an entire codebase for robustness issues.

  Scans all Elixir and JavaScript files, aggregates findings,
  and generates a comprehensive report.
  """
  @spec audit(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit(path, opts \\ []) do
    output_format = Keyword.get(opts, :format, :map)
    concurrency = Keyword.get(opts, :concurrency, 4)

    files = gather_files(path)

    results =
      files
      |> Task.async_stream(&analyze/1, max_concurrency: concurrency, timeout: 30_000)
      |> Enum.reduce(%{files: [], errors: [], stats: %{}}, fn
        {:ok, {:ok, result}}, acc ->
          %{acc | files: [result | acc.files]}

        {:ok, {:error, error}}, acc ->
          %{acc | errors: [error | acc.errors]}

        {:exit, reason}, acc ->
          %{acc | errors: [reason | acc.errors]}
      end)

    report = build_audit_report(results, path)

    case output_format do
      :markdown -> {:ok, format_as_markdown(report)}
      :map -> {:ok, report}
      _ -> {:ok, report}
    end
  end

  @doc """
  Check if code passes robustness threshold.

  Used for PR review integration - returns true if score >= threshold.
  Default threshold is 60 (warning) or 40 (blocking).
  """
  @spec passes?(String.t(), keyword()) :: boolean()
  def passes?(file_path, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 60)

    case analyze(file_path) do
      {:ok, %{score: score}} -> score >= threshold
      {:error, _} -> false
    end
  end

  @doc """
  Parse an incident report and extract patterns.

  Learns from past incidents to improve pattern detection.
  """
  @spec learn_from_incident(String.t()) :: {:ok, map()} | {:error, term()}
  def learn_from_incident(incident_content) do
    IncidentParser.parse(incident_content)
  end

  # --- Private Functions ---

  defp detect_language(file_path) do
    cond do
      String.ends_with?(file_path, ".ex") -> :elixir
      String.ends_with?(file_path, ".exs") -> :elixir
      String.ends_with?(file_path, ".js") -> :javascript
      String.ends_with?(file_path, ".ts") -> :typescript
      true -> :unknown
    end
  end

  defp calculate_score(patterns, complexity) do
    # Base score of 100
    base_score = 100

    # Deduct for red flags (20 points each, max 80)
    red_flag_penalty = min(length(patterns) * 20, 80)

    # Deduct for complexity (0.5 points per unit over threshold of 10)
    complexity_score = Map.get(complexity, :cyclomatic, 0)
    complexity_penalty = max(0, (complexity_score - 10) * 0.5)

    # Deduct for missing fallbacks (10 points each)
    missing_fallbacks = Map.get(complexity, :missing_fallbacks, 0)
    fallback_penalty = missing_fallbacks * 10

    # Calculate final score, clamped to 0-100
    max(0, round(base_score - red_flag_penalty - complexity_penalty - fallback_penalty))
  end

  defp generate_recommendations(patterns, complexity) do
    pattern_recommendations =
      Enum.map(patterns, fn pattern ->
        %{
          type: :red_flag,
          pattern: pattern.id,
          severity: pattern.severity,
          message: pattern.fix_template,
          line: pattern.line
        }
      end)

    complexity_recommendations =
      if Map.get(complexity, :cyclomatic, 0) > 10 do
        [
          %{
            type: :complexity,
            severity: :medium,
            message: "Consider extracting complex functions into smaller units"
          }
        ]
      else
        []
      end

    pattern_recommendations ++ complexity_recommendations
  end

  defp gather_files(path) do
    # Gather Elixir and JavaScript files
    elixir_files = Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
    js_files = Path.wildcard(Path.join(path, "**/*.{js,ts}"))

    # Filter out test files and deps
    (elixir_files ++ js_files)
    |> Enum.reject(&String.contains?(&1, "deps/"))
    |> Enum.reject(&String.contains?(&1, "_build/"))
    |> Enum.reject(&String.contains?(&1, "node_modules/"))
  end

  defp build_audit_report(results, path) do
    files = results.files
    total = length(files)

    # Calculate statistics
    scores = Enum.map(files, & &1.score)
    avg_score = if total > 0, do: Enum.sum(scores) / total, else: 0
    min_score = if total > 0, do: Enum.min(scores), else: 0
    max_score = if total > 0, do: Enum.max(scores), else: 0

    # Count by severity
    high_risk = Enum.count(files, &(&1.score < 40))
    medium_risk = Enum.count(files, &(&1.score >= 40 and &1.score < 60))
    low_risk = Enum.count(files, &(&1.score >= 60))

    # All red flags
    all_red_flags = Enum.flat_map(files, & &1.red_flags)

    %{
      path: path,
      generated_at: DateTime.utc_now(),
      summary: %{
        total_files: total,
        average_score: round(avg_score * 10) / 10,
        min_score: min_score,
        max_score: max_score,
        high_risk_files: high_risk,
        medium_risk_files: medium_risk,
        low_risk_files: low_risk,
        total_red_flags: length(all_red_flags)
      },
      high_risk_files: Enum.filter(files, &(&1.score < 40)) |> Enum.sort_by(& &1.score),
      all_red_flags: all_red_flags,
      errors: results.errors
    }
  end

  defp format_as_markdown(report) do
    """
    # 🛡️ Robustness Audit Report

    **Path:** #{report.path}
    **Generated:** #{report.generated_at}

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Total Files | #{report.summary.total_files} |
    | Average Score | #{report.summary.average_score}/100 |
    | Min Score | #{report.summary.min_score} |
    | Max Score | #{report.summary.max_score} |
    | High Risk (< 40) | #{report.summary.high_risk_files} |
    | Medium Risk (40-59) | #{report.summary.medium_risk_files} |
    | Low Risk (≥ 60) | #{report.summary.low_risk_files} |
    | Total Red Flags | #{report.summary.total_red_flags} |

    ## High Risk Files

    #{format_high_risk_files(report.high_risk_files)}

    ## Red Flags Detected

    #{format_red_flags(report.all_red_flags)}

    ---
    *Generated by Mimo Robustness Framework (SPEC-070)*
    """
  end

  defp format_high_risk_files([]), do: "_No high risk files found. ✅_"

  defp format_high_risk_files(files) do
    Enum.map_join(files, "\n", fn file ->
      "- **#{file.file}** - Score: #{file.score}/100 (#{length(file.red_flags)} red flags)"
    end)
  end

  defp format_red_flags([]), do: "_No red flags detected. ✅_"

  defp format_red_flags(flags) do
    flags
    |> Enum.group_by(& &1.id)
    |> Enum.map_join("\n", fn {id, instances} ->
      "- **#{id}** (#{length(instances)} instances)"
    end)
  end
end
