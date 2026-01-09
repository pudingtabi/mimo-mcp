defmodule Mimo.Cognitive.Amplifier.SynthesisEnforcer do
  @moduledoc """
  Forces integration of all reasoning threads before conclusion.

  Ensures the LLM doesn't just accumulate thoughts but actually
  synthesizes them into a coherent, grounded conclusion.

  ## Synthesis Requirements

  - All decomposition sub-problems addressed
  - All must-address challenges resolved
  - Key perspectives integrated
  - Trade-offs explicitly stated
  - Confidence level justified

  ## Integration

  Uses the accumulated state from AmplificationSession to verify
  completeness and generate synthesis prompts.
  """

  require Logger

  alias Mimo.Cognitive.Amplifier.AmplificationSession

  @type synthesis_thread :: %{
          type: atom(),
          content: String.t(),
          addressed: boolean()
        }

  @type synthesis_result :: %{
          ready: boolean(),
          completeness: float(),
          missing_threads: [synthesis_thread()],
          synthesis_prompt: String.t()
        }

  # Minimum completeness to allow synthesis
  @completeness_threshold 0.8

  @doc """
  Check if synthesis can proceed and generate synthesis prompt.
  """
  @spec prepare(String.t()) :: {:ok, synthesis_result()} | {:error, term()}
  def prepare(session_id) do
    case AmplificationSession.prepare_synthesis(session_id) do
      {:ok, prep} ->
        threads = collect_all_threads(prep.threads)
        missing = find_missing_threads(threads)
        completeness = calculate_completeness(threads)

        result = %{
          ready: completeness >= @completeness_threshold,
          completeness: Float.round(completeness, 3),
          missing_threads: missing,
          synthesis_prompt: generate_synthesis_prompt(threads, missing, completeness)
        }

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a synthesis prompt from threads.
  """
  @spec generate_synthesis_prompt(map(), [synthesis_thread()], float()) :: String.t()
  def generate_synthesis_prompt(threads, missing, completeness) do
    parts = ["## SYNTHESIS REQUIRED\n"]

    # Add completeness status
    parts =
      if completeness >= @completeness_threshold do
        [
          "✅ Sufficient coverage (#{Float.round(completeness * 100, 1)}%). Ready to synthesize.\n"
          | parts
        ]
      else
        [
          "⚠️ Incomplete coverage (#{Float.round(completeness * 100, 1)}%). Address missing items first.\n"
          | parts
        ]
      end

    # Add missing items if any
    parts =
      if missing != [] do
        missing_str =
          Enum.map_join(missing, "\n", &"- #{&1.type}: #{String.slice(&1.content, 0..80)}")

        ["### Missing:\n#{missing_str}\n" | parts]
      else
        parts
      end

    # Add synthesis guidance
    guidance = generate_synthesis_guidance(threads)
    parts = [guidance | parts]

    Enum.reverse(parts) |> Enum.join("\n")
  end

  @doc """
  Validate that a synthesis response is adequate.
  """
  @spec validate_synthesis(String.t(), map()) :: {:valid | :incomplete, [String.t()]}
  def validate_synthesis(response, threads) do
    issues = []

    # Check length
    issues =
      if String.length(response) < 200 do
        ["Synthesis too brief - please provide more integration of your reasoning" | issues]
      else
        issues
      end

    # Check that key threads are mentioned
    thread_terms = extract_thread_terms(threads)

    mentioned =
      Enum.count(thread_terms, fn term ->
        String.contains?(String.downcase(response), String.downcase(term))
      end)

    coverage = if thread_terms == [], do: 1.0, else: mentioned / length(thread_terms)

    issues =
      if coverage < 0.5 do
        ["Synthesis doesn't integrate all threads - please address all considerations" | issues]
      else
        issues
      end

    # Check for conclusion markers
    has_conclusion =
      String.match?(
        response,
        ~r/\b(therefore|thus|in conclusion|to summarize|the answer|the solution|recommend)\b/i
      )

    issues =
      if has_conclusion do
        issues
      else
        ["Please include a clear conclusion or recommendation" | issues]
      end

    if issues == [] do
      {:valid, []}
    else
      {:incomplete, Enum.reverse(issues)}
    end
  end

  @doc """
  Generate a forcing prompt for incomplete synthesis.
  """
  @spec force_completion([String.t()]) :: String.t()
  def force_completion(issues) do
    issue_str = Enum.map_join(issues, "\n", &"- #{&1}")

    """
    Your synthesis is incomplete. Please address:

    #{issue_str}

    Provide a revised synthesis that integrates all your reasoning into a coherent conclusion.
    """
  end

  defp collect_all_threads(raw_threads) do
    threads = []

    # Decomposition threads
    threads =
      if raw_threads.decomposition && raw_threads.decomposition != [] do
        decomp_threads =
          Enum.map(raw_threads.decomposition, fn {sub_problem, answered} ->
            %{
              type: :decomposition,
              content: sub_problem,
              addressed: answered
            }
          end)

        threads ++ decomp_threads
      else
        threads
      end

    # Challenge threads
    threads =
      if raw_threads.challenges && raw_threads.challenges != [] do
        challenge_threads =
          Enum.map(raw_threads.challenges, fn c ->
            %{
              type: :challenge,
              content: c.content,
              addressed: c.response != nil
            }
          end)

        threads ++ challenge_threads
      else
        threads
      end

    # Perspective threads
    threads =
      if raw_threads.perspectives && raw_threads.perspectives != [] do
        perspective_threads =
          Enum.map(raw_threads.perspectives, fn insight ->
            %{
              type: :perspective,
              content: insight,
              addressed: true
            }
          end)

        threads ++ perspective_threads
      else
        threads
      end

    threads
  end

  defp find_missing_threads(threads) do
    Enum.filter(threads, fn t -> not t.addressed end)
  end

  defp calculate_completeness(threads) do
    if threads == [] do
      1.0
    else
      addressed = Enum.count(threads, & &1.addressed)
      addressed / length(threads)
    end
  end

  defp generate_synthesis_guidance(threads) do
    # Group threads by type
    decomp = Enum.filter(threads, &(&1.type == :decomposition)) |> Enum.map(& &1.content)
    challenges = Enum.filter(threads, &(&1.type == :challenge)) |> Enum.map(& &1.content)
    perspectives = Enum.filter(threads, &(&1.type == :perspective)) |> Enum.map(& &1.content)

    parts = ["### Synthesize the following into a coherent conclusion:\n"]

    parts =
      if decomp != [] do
        decomp_str = Enum.map_join(Enum.take(decomp, 3), "\n", &"- #{String.slice(&1, 0..60)}")
        ["**Sub-problems addressed:**\n#{decomp_str}\n" | parts]
      else
        parts
      end

    parts =
      if challenges != [] do
        chal_str =
          Enum.map_join(Enum.take(challenges, 3), "\n", &"- #{String.slice(&1, 0..60)}")

        ["**Challenges considered:**\n#{chal_str}\n" | parts]
      else
        parts
      end

    parts =
      if perspectives != [] do
        persp_str =
          Enum.map_join(Enum.take(perspectives, 3), "\n", &"- #{String.slice(&1, 0..60)}")

        ["**Perspective insights:**\n#{persp_str}\n" | parts]
      else
        parts
      end

    # Add synthesis instructions
    instructions = """
    **Your synthesis should:**
    1. Integrate all the above considerations
    2. Explicitly state any trade-offs
    3. Acknowledge remaining uncertainties
    4. Provide a clear, actionable conclusion
    """

    [instructions | parts] |> Enum.reverse() |> Enum.join("\n")
  end

  defp extract_thread_terms(threads) do
    threads
    |> Enum.flat_map(fn
      %{decomposition: items} when is_list(items) ->
        Enum.flat_map(items, fn {content, _} -> extract_key_terms(content) end)

      %{challenges: items} when is_list(items) ->
        Enum.flat_map(items, &extract_key_terms(&1.content))

      %{perspectives: items} when is_list(items) ->
        Enum.flat_map(items, &extract_key_terms/1)

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp extract_key_terms(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/)
    |> Enum.filter(&(String.length(&1) > 5))
    |> Enum.take(3)
  end

  defp extract_key_terms(_), do: []
end
