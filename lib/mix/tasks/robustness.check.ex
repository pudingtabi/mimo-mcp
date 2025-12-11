defmodule Mix.Tasks.Robustness.Check do
  @shortdoc "Check specific files for robustness (SPEC-070 PR Integration)"

  @moduledoc """
  Checks specific files for robustness issues.

  Designed for PR review integration - checks changed files and outputs
  actionable feedback for developers.

  ## Usage

      # Check single file
      mix robustness.check lib/mimo/file.ex
      
      # Check multiple files
      mix robustness.check lib/file1.ex lib/file2.ex
      
      # CI mode with exit code
      mix robustness.check --strict lib/file.ex
      
      # Output PR comment format
      mix robustness.check --pr-comment lib/file.ex

  ## Options

    * `--strict` - Exit with error if any file scores below 40
    * `--warn` - Exit with error if any file scores below 60
    * `--pr-comment` - Output in GitHub PR comment markdown format
    * `--json` - Output in JSON format

  ## Exit Codes

    * 0 - All files pass threshold
    * 1 - One or more files below threshold

  ## PR Integration Example

  In your GitHub Action:

      - name: Robustness Check
        run: |
          changed_files=$(git diff --name-only ${{ github.event.before }} ${{ github.sha }} | grep -E '\\.(ex|js|ts)$')
          mix robustness.check --pr-comment $changed_files
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # Start required applications
    Mix.Task.run("app.start")

    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          strict: :boolean,
          warn: :boolean,
          pr_comment: :boolean,
          json: :boolean
        ]
      )

    if files == [] do
      Mix.shell().error("No files specified. Usage: mix robustness.check [options] file1 file2 ...")
      exit({:shutdown, 1})
    end

    results =
      Enum.map(files, fn file ->
        case Mimo.Robustness.analyze(file) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, file, reason}
        end
      end)

    # Separate successes and failures
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    success_results = Enum.map(successes, fn {:ok, r} -> r end)

    # Output results
    output_results(success_results, failures, opts)

    # Determine exit code
    determine_exit_code(success_results, opts)
  end

  defp output_results(results, failures, opts) do
    cond do
      Keyword.get(opts, :json, false) ->
        output_json(results, failures)

      Keyword.get(opts, :pr_comment, false) ->
        output_pr_comment(results, failures)

      true ->
        output_console(results, failures)
    end
  end

  defp output_console(results, failures) do
    Mix.shell().info("\n🛡️  Robustness Check - SPEC-070\n")

    Enum.each(results, fn r ->
      emoji = score_emoji(r.score)
      Mix.shell().info("#{emoji} #{r.file} - Score: #{r.score}/100")

      if r.red_flags != [] do
        Enum.each(Enum.take(r.red_flags, 3), fn flag ->
          Mix.shell().info("   └─ ❌ Line #{flag.line}: #{flag.description}")
        end)

        remaining = length(r.red_flags) - 3

        if remaining > 0 do
          Mix.shell().info("   └─ ... and #{remaining} more")
        end
      end
    end)

    Enum.each(failures, fn {:error, file, reason} ->
      Mix.shell().error("⚠️  #{file} - Error: #{inspect(reason)}")
    end)

    # Summary
    avg_score =
      if results != [] do
        Enum.sum(Enum.map(results, & &1.score)) / length(results)
      else
        0
      end

    Mix.shell().info("\n📊 Average Score: #{Float.round(avg_score, 1)}/100")
  end

  defp output_json(results, failures) do
    output = %{
      results: results,
      failures:
        Enum.map(failures, fn {:error, file, reason} ->
          %{file: file, error: inspect(reason)}
        end),
      summary: %{
        total_files: length(results) + length(failures),
        checked: length(results),
        errors: length(failures),
        average_score:
          if(results != [], do: Enum.sum(Enum.map(results, & &1.score)) / length(results), else: 0)
      }
    }

    Mix.shell().info(Jason.encode!(output, pretty: true))
  end

  defp output_pr_comment(results, failures) do
    all_red_flags = Enum.flat_map(results, & &1.red_flags)

    avg_score =
      if results != [] do
        Enum.sum(Enum.map(results, & &1.score)) / length(results)
      else
        0
      end

    score_status =
      cond do
        avg_score >= 60 -> "✅ Approved"
        avg_score >= 40 -> "⚠️ Needs Review"
        true -> "❌ Blocked"
      end

    comment = """
    ## 🛡️ Robustness Analysis

    **Overall Score:** #{Float.round(avg_score, 1)}/100 (#{score_status})

    ### Files Analyzed (#{length(results)})

    #{format_file_table(results)}

    #{format_red_flags_section(all_red_flags)}

    #{format_recommendations(results)}

    ---
    📚 See [IMPLEMENTATION_ROBUSTNESS.md](docs/IMPLEMENTATION_ROBUSTNESS.md) for patterns and fixes.

    *Generated by Mimo Robustness Framework (SPEC-070)*
    """

    Mix.shell().info(comment)

    if failures != [] do
      Mix.shell().error("\n⚠️ Could not analyze #{length(failures)} file(s)")
    end
  end

  defp format_file_table(results) do
    header = "| File | Score | Red Flags |"
    divider = "|------|-------|-----------|"

    rows =
      Enum.map(results, fn r ->
        emoji = score_emoji(r.score)
        "| #{emoji} #{Path.basename(r.file)} | #{r.score}/100 | #{length(r.red_flags)} |"
      end)

    [header, divider | rows] |> Enum.join("\n")
  end

  defp format_red_flags_section([]),
    do: """
    ### Red Flags Detected (0)

    _No red flags found in changed files. ✅_
    """

  defp format_red_flags_section(flags) do
    grouped = Enum.group_by(flags, & &1.id)

    flag_list =
      Enum.map(grouped, fn {id, instances} ->
        fix = List.first(instances).fix_template
        "- **#{id}** (#{length(instances)}x): #{fix}"
      end)
      |> Enum.join("\n")

    """
    ### Red Flags Detected (#{length(flags)})

    #{flag_list}
    """
  end

  defp format_recommendations(results) do
    all_recommendations =
      results
      |> Enum.flat_map(& &1.recommendations)
      |> Enum.uniq_by(& &1.message)
      |> Enum.take(5)

    if all_recommendations == [] do
      ""
    else
      recs =
        Enum.map(all_recommendations, fn r ->
          "1. #{r.message}"
        end)
        |> Enum.join("\n")

      """
      ### Recommendations

      #{recs}
      """
    end
  end

  defp score_emoji(score) when score >= 60, do: "✅"
  defp score_emoji(score) when score >= 40, do: "⚠️"
  defp score_emoji(_), do: "❌"

  defp determine_exit_code(results, opts) do
    min_score = if results != [], do: Enum.min_by(results, & &1.score).score, else: 0

    cond do
      Keyword.get(opts, :strict, false) and min_score < 40 ->
        Mix.shell().error("\n❌ STRICT: One or more files scored below 40")
        exit({:shutdown, 1})

      Keyword.get(opts, :warn, false) and min_score < 60 ->
        Mix.shell().error("\n❌ WARN: One or more files scored below 60")
        exit({:shutdown, 1})

      true ->
        :ok
    end
  end
end
